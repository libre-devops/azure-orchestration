# Libre DevOps orchestration task runner. Run `just` to list recipes.
#
# The pipelines in .github/workflows are the supported way to deploy; these recipes cover the
# offline checks, starting the pipelines, and closing a bastion session a failed local apply left.

set shell := ["bash", "-euo", "pipefail", "-c"]

# List available recipes.
default:
    @just --list

# Offline checks as CI runs them: fmt, validate, tflint, trivy.
validate:
    terraform fmt -check -recursive
    for d in stacks/*/; do \
      echo "== ${d%/} =="; \
      terraform -chdir="${d%/}" init -backend=false -input=false >/dev/null; \
      terraform -chdir="${d%/}" validate; \
      (cd "${d%/}" && tflint --init >/dev/null && tflint --recursive); \
    done
    trivy config --quiet --ignorefile .trivyignore.yaml --severity HIGH,CRITICAL --exit-code 1 .

# Run the MDE Linux deploy pipeline. Example: just deploy dev key true (key sign-in, destroy afterwards)
deploy workspace="dev" ssh_auth="entra" destroy_after="false":
    gh workflow run mde-linux-deploy.yml -f workspace='{{ workspace }}' -f ssh_auth='{{ ssh_auth }}' -f destroy_after='{{ destroy_after }}'

# Close a leftover bastion session in Azure now rather than waiting for the hourly sweep.
close-access workspace="dev":
    gh workflow run mde-linux-close-access.yml -f workspace='{{ workspace }}'

# Close the bastion session a failed local apply left open (az login first). Does nothing when none is.
close stack="mde-linux" session="mde-linux":
    stacks/{{ stack }}/.terraform/modules/bastion_session/scripts/close.sh stacks/{{ stack }}/.terraform/bastion-session/{{ session }}
