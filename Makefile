SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

TF_ARGS ?=
DICOM_FILE ?=
PRIVATE_KEY ?= $(HOME)/.ssh/id_rsa

.PHONY: \
	help init fmt validate plan show-plan apply apply-auto outputs verify \
	verify-dicom verify-dicom-clean get-credentials configure-bastion \
	bastion-status destroy destroy-auto destroy-purge destroy-purge-auto

help: ## Show the available deployment commands.
	@printf '%s\n' \
		'OCI DICOM deployment targets:' \
		'' \
		'  make validate             Run Terraform, shell, JSON, and Ansible checks' \
		'  make plan                 Create terraform/dicom.tfplan without applying it' \
		'  make show-plan            Display the saved Terraform plan' \
		'  make apply                Plan and apply interactively' \
		'  make apply-auto           Plan and apply without confirmation' \
		'  make verify               Test Orthanc REST and DICOMweb' \
		'  make verify-dicom       Upload a synthetic DICOM and keep it visible in Orthanc' \
		'  make verify-dicom-clean Upload, verify, and remove a synthetic DICOM' \
		'  make verify-dicom DICOM_FILE=/absolute/test.dcm  Test a supplied DICOM instead' \
		'  make get-credentials      Display the Orthanc credentials and Web UI URL' \
		'  make configure-bastion    Configure the bastion with Ansible' \
		'  make bastion-status       Test the private stack from the bastion' \
		'  make outputs              Show the non-secret deployment summary' \
		'  make destroy              Destroy; preserve a non-empty DICOM bucket' \
		'  make destroy-auto         Same data-preserving destroy without confirmation' \
		'  make destroy-purge        Permanently purge the bucket, then destroy' \
		'  make destroy-purge-auto   Purge and destroy without confirmation (dangerous)' \
		'' \
		'Optional overrides:' \
		'  TF_ARGS="-var=name=value" PRIVATE_KEY=/absolute/path/to/id_rsa'

init: ## Initialize Terraform providers and backend.
	terraform -chdir=terraform init

fmt: ## Format all Terraform files.
	terraform -chdir=terraform fmt -recursive

validate: ## Run all static deployment checks.
	./scripts/validate.sh

plan: ## Create a saved, state-aware Terraform plan.
	./scripts/deploy.sh --plan-only $(TF_ARGS)

show-plan: ## Display the saved Terraform plan.
	@test -f terraform/dicom.tfplan || { printf '%s\n' 'terraform/dicom.tfplan is missing; run make plan first.' >&2; exit 1; }
	terraform -chdir=terraform show dicom.tfplan

apply: ## Plan, apply interactively, and configure the bastion.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	BASTION_SSH_PRIVATE_KEY_FILE="$(PRIVATE_KEY)" ./scripts/deploy.sh $(TF_ARGS)

apply-auto: ## Plan and apply without confirmation, then configure the bastion.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	BASTION_SSH_PRIVATE_KEY_FILE="$(PRIVATE_KEY)" ./scripts/deploy.sh --auto-approve $(TF_ARGS)

outputs: ## Show the non-secret deployment summary.
	terraform -chdir=terraform output deployment_summary

verify: ## Check public Orthanc REST and DICOMweb endpoints.
	./scripts/verify.sh

verify-dicom: ## Upload and retain one non-production DICOM instance.
	@set -euo pipefail; \
	if [[ -n "$(DICOM_FILE)" ]]; then \
		./scripts/verify.sh --dicom "$(DICOM_FILE)"; \
	else \
		test_dicom="$$(mktemp "$${TMPDIR:-/tmp}/oci-dicom-test.XXXXXX")"; \
		trap 'rm -f "$${test_dicom}"' EXIT; \
		./scripts/generate-test-dicom.py "$${test_dicom}"; \
		./scripts/verify.sh --dicom "$${test_dicom}"; \
	fi

verify-dicom-clean: ## Upload, verify, and remove one synthetic DICOM instance.
	@set -euo pipefail; \
	test_dicom="$$(mktemp "$${TMPDIR:-/tmp}/oci-dicom-test.XXXXXX")"; \
	trap 'rm -f "$${test_dicom}"' EXIT; \
	./scripts/generate-test-dicom.py "$${test_dicom}"; \
	./scripts/verify.sh --dicom "$${test_dicom}" --delete-after-upload

get-credentials: ## Display the Orthanc login credentials and Web UI endpoint.
	@printf 'Username: '
	@terraform -chdir=terraform output -raw orthanc_username
	@printf '\nPassword: '
	@terraform -chdir=terraform output -raw orthanc_password
	@printf '\nOrthanc Web UI: '
	@terraform -chdir=terraform output -raw api_endpoint
	@printf '/ui/app/\n'

configure-bastion: ## Apply the Ansible operator configuration to the bastion.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	./scripts/configure-bastion.sh --private-key "$(PRIVATE_KEY)"

bastion-status: ## Test private Orthanc, DICOMweb, and PostgreSQL from the bastion.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	./scripts/ssh-bastion.sh --private-key "$(PRIVATE_KEY)" sudo dicom-status

destroy: ## Plan and destroy the stack with confirmation.
	./scripts/destroy.sh

destroy-auto: ## Destroy the stack without confirmation.
	./scripts/destroy.sh --auto-approve

destroy-purge: ## Permanently purge the Object Storage bucket and destroy the stack.
	./scripts/destroy.sh --purge-bucket

destroy-purge-auto: ## Permanently purge and destroy without confirmation.
	./scripts/destroy.sh --purge-bucket --auto-approve
