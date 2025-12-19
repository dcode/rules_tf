load("@rules_tf//tf/rules:providers.bzl", "TfModuleInfo")
load("@bazel_skylib//lib:paths.bzl", "paths")

def _tf_package_impl(ctx):
    tf_runtime = ctx.toolchains["@rules_tf//:tf_toolchain_type"].runtime
    module = ctx.attr.module[TfModuleInfo]

    # Collect all transitive sources
    all_srcs = module.transitive_srcs.to_list()
    var_files = ctx.files.tf_vars_files
    backend_config = ctx.file.tf_backend_config

    # Output tarball
    output_tar = ctx.actions.declare_file("{}.{}.tar.gz".format(ctx.label.name, tf_runtime.arch))

    # Helper script to generate manifest and tarball
    builder_script = ctx.actions.declare_file(ctx.label.name + "_builder.py")

    # We use template substitution for the python script to avoid conflicts with python's own {}
    # and to inject the architecture.
    builder_content = """
import os
import tarfile
import hashlib
import json
import sys
import shutil

def sha256_file(filepath):
    hash_sha256 = hashlib.sha256()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            hash_sha256.update(chunk)
    return hash_sha256.hexdigest()

def main():
    output_tar_path = sys.argv[1]
    tf_binary = sys.argv[2]
    mirror_dir = sys.argv[3]
    module_path = sys.argv[4]
    run_sh_path = sys.argv[5]

    files_map = {}
    for arg in sys.argv[6:]:
        if "=" in arg:
            dst, src = arg.split("=", 1)
            files_map[dst] = src

    manifest_files = []

    # We will collect operations to perform on the tarball
    # list of (local_path, arc_name)
    files_to_add = []

    # Add run.sh
    files_to_add.append((run_sh_path, "run.sh"))
    manifest_files.append({
        "path": "run.sh",
        "sha256": sha256_file(run_sh_path)
    })

    # Add binary
    bin_name = os.path.basename(tf_binary)
    files_to_add.append((tf_binary, "bin/" + bin_name))
    manifest_files.append({
        "path": "bin/" + bin_name,
        "sha256": sha256_file(tf_binary)
    })

    # Add mirror
    for root, dirs, files in os.walk(mirror_dir):
        for file in files:
            full_path = os.path.join(root, file)
            rel_path = os.path.relpath(full_path, mirror_dir)
            arc_path = "mirror/" + rel_path
            files_to_add.append((full_path, arc_path))
            manifest_files.append({
                "path": arc_path,
                "sha256": sha256_file(full_path)
            })

    # Add sources
    for dst, src in files_map.items():
        arc_path = "src/" + dst
        files_to_add.append((src, arc_path))
        manifest_files.append({
            "path": arc_path,
            "sha256": sha256_file(src)
        })

    # Create manifest
    manifest = {
        "arch": "%ARCH%",
        "entrypoint": "run.sh",
        "files": manifest_files
    }

    with open("manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)

    # Add manifest to the list
    files_to_add.append(("manifest.json", "manifest.json"))

    # Write tarball
    with tarfile.open(output_tar_path, "w:gz") as tar:
        for local_path, arc_name in files_to_add:
            tar.add(local_path, arcname=arc_name)

if __name__ == "__main__":
    main()
"""
    # Replace the placeholder manually
    builder_content = builder_content.replace("%ARCH%", tf_runtime.arch)

    ctx.actions.write(builder_script, builder_content)

    tf_bin_name = tf_runtime.tf.basename

    var_args_list = []
    for vf in var_files:
         var_args_list.append("-var-file=$ROOT/src/" + vf.path)

    var_args_str = " ".join(var_args_list)

    backend_args_str = ""
    if backend_config:
        backend_args_str = "-backend-config=$ROOT/src/" + backend_config.path
    elif ctx.attr.tf_backend_config_vals:
        vals = []
        for kv in ctx.attr.tf_backend_config_vals.split(","):
            vals.append("-backend-config=" + kv)
        backend_args_str = " ".join(vals)

    run_script = ctx.actions.declare_file("run.sh")
    run_script_content = """#!/bin/bash
set -e

ROOT=$(pwd)
BIN=$ROOT/bin/{bin_name}
PLUGIN_DIR=$ROOT/mirror
SRC_DIR=$ROOT/src/{module_dir}

export TF_IN_AUTOMATION=1

CMD="apply"
OUT_FILE=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --plan) CMD="plan" ;;
        --out) OUT_FILE="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

echo "Running terraform $CMD..."

# Init
$BIN -chdir=$SRC_DIR init -input=false -plugin-dir=$PLUGIN_DIR {backend_args}

if [ "$CMD" = "plan" ]; then
    PLAN_ARGS=""
    if [ -n "$OUT_FILE" ]; then
        if [[ "$OUT_FILE" != /* ]]; then
            OUT_FILE="$ROOT/$OUT_FILE"
        fi
        PLAN_ARGS="-out=$OUT_FILE"
    fi
    $BIN -chdir=$SRC_DIR plan -input=false $PLAN_ARGS {var_args}
else
    $BIN -chdir=$SRC_DIR apply -input=false -auto-approve {var_args}
fi
""".format(
        bin_name = tf_bin_name,
        module_dir = module.module_path,
        backend_args = backend_args_str,
        var_args = var_args_str
    )

    ctx.actions.write(run_script, run_script_content, is_executable=True)

    args = ctx.actions.args()
    args.add(output_tar)
    args.add(tf_runtime.tf)
    args.add(tf_runtime.mirror.path)
    args.add(module.module_path)
    args.add(run_script)

    for f in all_srcs:
        args.add("{}={}".format(f.path, f.path))
    for f in var_files:
        args.add("{}={}".format(f.path, f.path))
    if backend_config:
         args.add("{}={}".format(backend_config.path, backend_config.path))

    inputs = all_srcs + var_files + tf_runtime.deps + [run_script, builder_script]
    if backend_config:
        inputs.append(backend_config)

    ctx.actions.run(
        outputs = [output_tar],
        inputs = inputs,
        executable = "python3",
        arguments = [builder_script.path, args],
        mnemonic = "TfPackage",
    )

    return [DefaultInfo(files = depset([output_tar]))]

tf_package = rule(
    implementation = _tf_package_impl,
    attrs = {
        "module": attr.label(providers = [TfModuleInfo], mandatory = True),
        "tf_vars_files": attr.label_list(allow_files = True),
        "tf_backend_config": attr.label(allow_single_file = True),
        "tf_backend_config_vals": attr.string(),
    },
    toolchains = ["@rules_tf//:tf_toolchain_type"],
)

def tf_deployment(name, **kwargs):
    tf_package(name = name, **kwargs)
