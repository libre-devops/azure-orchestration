# Libre DevOps orchestration task runner. Run `just` to list recipes.
#
# The pipelines in .github/workflows are the supported way to deploy; these recipes cover the
# offline checks and running the Ansible step yourself against a stack whose access window is open.

set shell := ["bash", "-euo", "pipefail", "-c"]

# List available recipes.
default:
    @just --list

# Install the Ansible roles from ansible/requirements.yml into ansible/roles.
deps:
    ansible-galaxy role install -r ansible/requirements.yml -p ansible/roles --force

# Offline checks as CI runs them: fmt, validate, tflint, trivy, shellcheck, Ansible syntax.
validate: deps
    terraform fmt -check -recursive
    for d in stacks/*/; do \
      echo "== ${d%/} =="; \
      terraform -chdir="${d%/}" init -backend=false -input=false >/dev/null; \
      terraform -chdir="${d%/}" validate; \
      (cd "${d%/}" && tflint --init >/dev/null && tflint --recursive); \
    done
    trivy config --quiet --ignorefile .trivyignore.yaml --severity HIGH,CRITICAL --exit-code 1 .
    shellcheck scripts/*.sh
    for p in ansible/playbooks/*.yml; do ANSIBLE_CONFIG=ansible/ansible.cfg ansible-playbook --syntax-check -i localhost, "$p"; done

# Run a playbook through an open access window; auth is entra or key. Example: just configure rg-mde-ldo-uks-dev-001 key
configure resource_group auth="entra" playbook="ansible/playbooks/mde-linux.yml": deps
    scripts/bastion-ansible.sh --resource-group '{{ resource_group }}' --playbook '{{ playbook }}' --auth '{{ auth }}'

# Run the MDE Linux deploy pipeline. Example: just deploy dev key true (key sign-in, destroy afterwards)
deploy workspace="dev" ssh_auth="entra" destroy_after="false":
    gh workflow run mde-linux-deploy.yml -f workspace='{{ workspace }}' -f ssh_auth='{{ ssh_auth }}' -f destroy_after='{{ destroy_after }}'

# Close a leftover access window now rather than waiting for the hourly sweep.
close-access workspace="dev":
    gh workflow run mde-linux-close-access.yml -f workspace='{{ workspace }}'
