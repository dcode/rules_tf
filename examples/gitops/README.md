# Bazel + Terraform GitOps Workflow

This directory demonstrates a GitOps workflow using Bazel and Terraform.

## Workflow Overview

1.  **Pull Request (PR):**
    *   Developers make changes to Terraform code.
    *   CI runs `bazel test //...`.
    *   `tf_plan_test` targets execute `terraform plan`.
    *   If `fail_on_diff = True` is set, the test **fails** if Terraform detects changes.
    *   This ensures that no unexpected infrastructure changes are merged.

2.  **Allowing Changes:**
    *   If a change is intentional, the developer (or automation) sets the `TF_EXPECT_CHANGE` environment variable.
    *   In a typical setup, this can be triggered by adding a label to the PR (e.g., `gitops:allow-change:module-name`) or parsing the commit message.
    *   The CI pipeline passes this variable to Bazel: `bazel test --test_env=TF_EXPECT_CHANGE=module-name //...`.
    *   The test checks if `TF_EXPECT_CHANGE` matches the current test target. If it does, the test passes even with a diff.

3.  **Merge (CD):**
    *   Once merged to `main`, the CD pipeline builds the deployment package (`tf_package`).
    *   The artifact is deployed (applied) using the generated `run.sh` script.

## Example Components

*   `main.tf`: A simple Terraform module using the `local` provider.
*   `BUILD.bazel`:
    *   `tf_module`: Bundles the Terraform module.
    *   `tf_plan_test`: Defines the plan test with `fail_on_diff = True`.
*   `mock_ci.sh`: A script simulating the CI/CD lifecycle.

## Usage

Run the mock CI script to see it in action:

```bash
./examples/gitops/mock_ci.sh
```

## Configuration

To enable the expect-change behavior, ensure your `tf_plan_test` definition has `fail_on_diff = True`.

```python
tf_plan_test(
    name = "plan",
    package = ":my_module",
    fail_on_diff = True,
)
```
