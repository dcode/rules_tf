load("//tf/rules:tf-module.bzl", "tf_module", "tf_validate_test")
load("//tf/rules:tf-deployment.bzl", "tf_package")
load("//tf/rules:tf-runner.bzl", "tf_runner")
load("//tf/rules:tf-plan-test.bzl", "tf_plan_test")
load("@rules_pkg//pkg:mappings.bzl", "pkg_files")

def tf_config(
        name,
        srcs = None,
        deps = None,
        tf_vars_files = None,
        tf_backend_config = None,
        tf_backend_config_vals = None,
        fail_on_diff = False,
        visibility = None,
        tags = []):
    """
    A comprehensive macro to define a Terraform root module and its associated rules.

    Args:
        name: The name of the module.
        srcs: Source files for the module (defaults to all *.tf, *.tf.json in package).
        deps: Dependencies (other tf_modules).
        tf_vars_files: List of tfvars files.
        tf_backend_config: Backend config file.
        tf_backend_config_vals: Backend config values (string).
        fail_on_diff: If True, the plan test will fail if changes are detected (Drift Check).
        visibility: Visibility of the targets.
        tags: Tags for the targets.
    """

    # 1. Define the module
    if srcs == None:
        srcs = native.glob(["*.tf", "*.tf.json"])

    # Wrap sources in pkg_files as expected by tf_module rule
    files_label = name + "_files"
    pkg_files(
        name = files_label,
        srcs = srcs,
        strip_prefix = "",
        prefix = native.package_name(),
        visibility = visibility,
        tags = tags,
    )

    tf_module(
        name = name,
        srcs = ":" + files_label,
        deps = deps,
        visibility = visibility,
    )

    # 2. Define the Golden Package
    pkg_name = name + "_pkg"
    tf_package(
        name = pkg_name,
        module = name,
        tf_vars_files = tf_vars_files,
        tf_backend_config = tf_backend_config,
        tf_backend_config_vals = tf_backend_config_vals,
        visibility = visibility,
        tags = tags,
    )

    # 3. Validation Test
    tf_validate_test(
        name = name + "_validate_test",
        module = name,
        visibility = visibility,
        tags = tags,
    )

    # 4. Plan Test (Diff Test)
    # This requires network usually
    plan_tags = [t for t in tags]
    if "external" not in plan_tags:
        plan_tags.append("external")
    if "requires-network" not in plan_tags:
        plan_tags.append("requires-network")

    tf_plan_test(
        name = name + "_plan_test",
        package = pkg_name,
        fail_on_diff = fail_on_diff,
        visibility = visibility,
        tags = plan_tags,
    )

    # 5. Interactive Runner
    # Used for 'bazel run //:name_apply -- apply' or 'bazel run //:name_apply -- plan'
    tf_runner(
        name = name + "_apply",
        module = name,
        tf_vars_files = tf_vars_files,
        tf_backend_config = tf_backend_config,
        tf_backend_config_vals = tf_backend_config_vals,
        visibility = visibility,
        tags = tags,
    )
