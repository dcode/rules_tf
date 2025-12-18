load("@rules_pkg//pkg:pkg.bzl", "pkg_tar")
load("@rules_pkg//pkg:mappings.bzl", "pkg_files")
load("@rules_tf//tf/rules:tf-gen-doc.bzl", _tf_gen_doc = "tf_gen_doc" )
load("@rules_tf//tf/rules:tf-gen-versions.bzl", "tf_gen_versions")
load("@rules_tf//tf/rules:tf-providers-versions.bzl", _tf_providers_versions = "tf_providers_versions")
load("@rules_tf//tf/rules:tf-lint.bzl", "tf_lint_test")
load("@rules_tf//tf/rules:tf-deployment.bzl", _tf_deployment = "tf_deployment")
load("@rules_tf//tf/rules:tf-module.bzl", _tf_module = "tf_module", "tf_module_deps", "tf_artifact", "tf_validate_test", _tf_format = "tf_format", "tf_format_test")

def tf_module(name,
              providers_versions = None,
              srcs= [],
              data = [],
              size="small",
              providers = [],
              tflint_config = None,
              tflint_extra_args = [],
              deps = [],
              experiments = [],
              visibility= ["//visibility:public"],
              tags = []):

    tf_gen_versions(
        name = "gen-tf-versions",
        providers = providers,
        providers_versions  = providers_versions,
        experiments = experiments,
        visibility = visibility,
        tags = tags,
    )

    pkg_files(
        name = "srcs",
        srcs = srcs + data,
        strip_prefix = "", # this is important to preserve directory structure
        prefix = native.package_name(),
        tags = tags,
        visibility = visibility,
    )

    _tf_module(
        name = "module",
        deps = deps,
        srcs = ":srcs",
        tags = tags,
    )

    tf_module_deps(
        name = "deps",
        mod = ":module",
        tags = tags,
    )

    tf_format_test(
        name = "format",
        size = size,
        module = ":module",
        tags = tags,
    )

    tf_lint_test(
        name = "lint",
        module = ":module",
        config = tflint_config,
        extra_args = tflint_extra_args,
        size = size,
        tags = tags,
    )

    tf_validate_test(
        name = "validate",
        module = ":module",
        size = size,
        tags = tags,
    )

    pkg_tar(
        name = "tgz",
        srcs = [ ":module", ":deps"],
        out = "{}.tar.gz".format(name),
        extension = "tar.gz",
        strip_prefix = ".", # this is important to preserve directory structure
        tags = tags,
    )

    tf_artifact(
        name = name,
        module = ":module",
        package = ":tgz",
        visibility = ["//visibility:public"],
        tags = tags,
    )


def tf_format(name, modules, **kwargs):
    _tf_format(
        name = name,
        modules = modules,
        visibility = ["//visibility:public"],
        **kwargs
    )

def tf_gen_doc(name, modules, config = None, **kwargs):
    _tf_gen_doc(
        name = name,
        modules = modules,
        config = config,
        visibility = ["//visibility:public"],
        **kwargs
    )

def tf_providers_versions(name, tf_version = "", providers = {}, tags = ["no-sandbox"], **kwargs):
    _tf_providers_versions(
        name = name,
        providers = providers,
        tf_version = tf_version,
        visibility = ["//visibility:public"],
        tags = tags,
        **kwargs
    )

def tf_deployment(name, module, tf_vars_files = None, tf_backend_config = None, visibility = ["//visibility:public"], **kwargs):
    _tf_deployment(
        name = name,
        module = module,
        tf_vars_files = tf_vars_files,
        tf_backend_config = tf_backend_config,
        visibility = visibility,
        **kwargs
    )
