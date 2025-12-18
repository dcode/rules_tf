load("@rules_tf//tf/rules:providers.bzl", "TfModuleInfo")
load("@bazel_skylib//lib:paths.bzl", "paths")

def _tf_plan_impl(ctx):
    tf_runtime = ctx.toolchains["@rules_tf//:tf_toolchain_type"].runtime
    module = ctx.attr.module[TfModuleInfo]

    # Collect all transitive sources
    all_srcs = module.transitive_srcs.to_list()

    # Collect var files
    var_files = ctx.files.tf_vars_files

    # Construct the command
    # We need to setup the workspace, link files, and run init + plan

    # Output plan file
    plan_file = ctx.actions.declare_file(ctx.label.name + ".tfplan")

    # Prepare var file arguments
    var_args = []
    for vf in var_files:
        var_args.append("-var-file=" + vf.path)

    # Backend config
    backend_args = []
    if ctx.file.tf_backend_config:
        backend_args.append("-backend-config=" + ctx.file.tf_backend_config.path)
        all_srcs.append(ctx.file.tf_backend_config)
    elif ctx.attr.tf_backend_config_vals:
        for kv in ctx.attr.tf_backend_config_vals.split(","):
            backend_args.append("-backend-config=" + kv)

    # Command construction
    # We use a wrapper script to handle the execution environment

    # Resolve plugin mirror path relative to execution root
    plugin_dir = tf_runtime.mirror.path

    # Construct the shell command
    # 1. Copy sources to a sandbox directory to avoid polluting source tree and handle generated files
    # However, Bazel sandboxing handles most of this. We just need to ensure we run in the right directory.
    # The `tf_module` rule preserves directory structure.

    # We need to run terraform in the directory containing the root module sources.
    # Since `tf_module` collects sources from deps, we rely on the `module_path` from TfModuleInfo.

    module_dir = module.module_path

    # Terraform init command
    init_cmd = "{tf} -chdir={dir} init -input=false -plugin-dir=$PWD/{plugin_dir}".format(
        tf = tf_runtime.tf.path,
        dir = module_dir,
        plugin_dir = plugin_dir,
    )
    for arg in backend_args:
        init_cmd += " " + arg

    # Terraform plan command
    # We need to output the plan to the declare_file location
    # Note: plan output path must be absolute or relative to the working directory (-chdir)
    # Since we use -chdir, we need to be careful.
    # $PWD is the runfiles root (execroot).
    # {plan_path} is relative to execroot.
    # So if we are in {dir}, we need to refer to $PWD/{plan_path}

    plan_cmd = "{tf} -chdir={dir} plan -input=false -out=$PWD/{plan_path}".format(
        tf = tf_runtime.tf.path,
        dir = module_dir,
        plan_path = plan_file.path,
    )
    for arg in var_args:
        plan_cmd += " " + arg

    # Combine commands
    cmd = "set -e\n" + init_cmd + "\n" + plan_cmd

    ctx.actions.run_shell(
        outputs = [plan_file],
        inputs = all_srcs + var_files + tf_runtime.deps,
        command = cmd,
        mnemonic = "TerraformPlan",
        use_default_shell_env = True,
    )

    return [
        DefaultInfo(files = depset([plan_file])),
        TfModuleInfo(
            files = module.files,
            deps = module.deps,
            transitive_srcs = module.transitive_srcs,
            module_path = module.module_path,
        )
    ]

tf_plan = rule(
    implementation = _tf_plan_impl,
    attrs = {
        "module": attr.label(providers = [TfModuleInfo], mandatory = True),
        "tf_vars_files": attr.label_list(allow_files = True),
        "tf_backend_config": attr.label(allow_single_file = True),
        "tf_backend_config_vals": attr.string(),
    },
    toolchains = ["@rules_tf//:tf_toolchain_type"],
)

def _tf_apply_impl(ctx):
    tf_runtime = ctx.toolchains["@rules_tf//:tf_toolchain_type"].runtime
    module = ctx.attr.module[TfModuleInfo]
    plan_file = ctx.file.plan

    # executable script
    script = ctx.actions.declare_file(ctx.label.name + ".sh")

    module_dir = module.module_path
    plugin_dir = tf_runtime.mirror.short_path

    # We need to re-init because apply is a separate action/run
    # For `bazel run`, we are in the runfiles tree.

    # Backend config (needed for init)
    backend_args = []
    if ctx.file.tf_backend_config:
        backend_args.append("-backend-config=$PWD/" + ctx.file.tf_backend_config.short_path)
    elif ctx.attr.tf_backend_config_vals:
        for kv in ctx.attr.tf_backend_config_vals.split(","):
            backend_args.append("-backend-config=" + kv)

    init_cmd = "{tf} -chdir={dir} init -input=false -plugin-dir=$PWD/{plugin_dir}".format(
        tf = tf_runtime.tf.short_path,
        dir = module_dir,
        plugin_dir = plugin_dir,
    )
    for arg in backend_args:
        init_cmd += " " + arg

    apply_cmd = "{tf} -chdir={dir} apply -input=false $PWD/{plan_path}".format(
        tf = tf_runtime.tf.short_path,
        dir = module_dir,
        plan_path = plan_file.short_path,
    )

    # Content of the wrapper script
    content = """#!/bin/bash
set -e
export TF_IN_AUTOMATION=1
{init_cmd}
{apply_cmd}
""".format(
        init_cmd = init_cmd,
        apply_cmd = apply_cmd,
    )

    ctx.actions.write(output = script, content = content, is_executable = True)

    runfiles = ctx.runfiles(
        files = module.transitive_srcs.to_list() +
                tf_runtime.deps +
                [plan_file] +
                ([ctx.file.tf_backend_config] if ctx.file.tf_backend_config else [])
    )

    return [DefaultInfo(executable = script, runfiles = runfiles)]

tf_apply = rule(
    implementation = _tf_apply_impl,
    attrs = {
        "module": attr.label(providers = [TfModuleInfo], mandatory = True),
        "plan": attr.label(allow_single_file = True, mandatory = True),
        "tf_backend_config": attr.label(allow_single_file = True),
        "tf_backend_config_vals": attr.string(),
    },
    executable = True,
    toolchains = ["@rules_tf//:tf_toolchain_type"],
)

def _tf_plan_test_impl(ctx):
    tf_runtime = ctx.toolchains["@rules_tf//:tf_toolchain_type"].runtime
    module = ctx.attr.module[TfModuleInfo]

    script = ctx.actions.declare_file(ctx.label.name + ".sh")

    module_dir = module.module_path
    plugin_dir = tf_runtime.mirror.short_path

    var_files = ctx.files.tf_vars_files
    var_args = []
    for vf in var_files:
        var_args.append("-var-file=$PWD/" + vf.short_path)

    backend_args = []
    if ctx.file.tf_backend_config:
        backend_args.append("-backend-config=$PWD/" + ctx.file.tf_backend_config.short_path)
    elif ctx.attr.tf_backend_config_vals:
        for kv in ctx.attr.tf_backend_config_vals.split(","):
            backend_args.append("-backend-config=" + kv)

    init_cmd = "{tf} -chdir={dir} init -input=false -plugin-dir=$PWD/{plugin_dir}".format(
        tf = tf_runtime.tf.short_path,
        dir = module_dir,
        plugin_dir = plugin_dir,
    )
    for arg in backend_args:
        init_cmd += " " + arg

    plan_cmd = "{tf} -chdir={dir} plan -input=false".format(
        tf = tf_runtime.tf.short_path,
        dir = module_dir,
    )
    for arg in var_args:
        plan_cmd += " " + arg

    content = """#!/bin/bash
set -e
export TF_IN_AUTOMATION=1
{init_cmd}
{plan_cmd}
""".format(init_cmd=init_cmd, plan_cmd=plan_cmd)

    ctx.actions.write(output = script, content = content, is_executable = True)

    runfiles = ctx.runfiles(
        files = module.transitive_srcs.to_list() +
                tf_runtime.deps +
                var_files +
                ([ctx.file.tf_backend_config] if ctx.file.tf_backend_config else [])
    )

    return [DefaultInfo(executable = script, runfiles = runfiles)]

tf_plan_test = rule(
    implementation = _tf_plan_test_impl,
    attrs = {
        "module": attr.label(providers = [TfModuleInfo], mandatory = True),
        "tf_vars_files": attr.label_list(allow_files = True),
        "tf_backend_config": attr.label(allow_single_file = True),
        "tf_backend_config_vals": attr.string(),
    },
    test = True,
    toolchains = ["@rules_tf//:tf_toolchain_type"],
)


def tf_deployment(name, module, tf_vars_files = None, tf_backend_config = None, **kwargs):

    if tf_vars_files == None:
        tf_vars_files = native.glob([
            "terraform.tfvars",
            "terraform.tfvars.json",
            "*.auto.tfvars",
            "*.auto.tfvars.json",
        ], allow_empty = True)

    backend_config_file = None
    backend_config_vals = None

    if tf_backend_config:
        if "=" in tf_backend_config:
            backend_config_vals = tf_backend_config
        else:
            backend_config_file = tf_backend_config

    plan_name = name + ".plan"
    apply_name = name + ".apply"
    test_name = name + ".test"

    tf_plan(
        name = plan_name,
        module = module,
        tf_vars_files = tf_vars_files,
        tf_backend_config = backend_config_file,
        tf_backend_config_vals = backend_config_vals,
        **kwargs
    )

    tf_apply(
        name = apply_name,
        module = module,
        plan = plan_name,
        tf_backend_config = backend_config_file,
        tf_backend_config_vals = backend_config_vals,
        **kwargs
    )

    tf_plan_test(
        name = test_name,
        module = module,
        tf_vars_files = tf_vars_files,
        tf_backend_config = backend_config_file,
        tf_backend_config_vals = backend_config_vals,
        **kwargs
    )

    native.filegroup(
        name = name,
        srcs = [plan_name],
        **kwargs
    )
