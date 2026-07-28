SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

TF_ARGS ?=
DICOM_FILE ?=
PRIVATE_KEY ?= $(HOME)/.ssh/id_rsa

.PHONY: \
	help init fmt validate plan show-plan apply apply-auto outputs verify \
	verify-dicom get-credentials configure-bastion bastion-status destroy \
	destroy-auto

help: ## Show the available deployment commands.
	@printf '%s\n' \
		'OCI DICOM deployment targets:' \
		'' \
		'  make validate             Run Terraform, shell, JSON, and Ansible checks' \
		'  make plan                 Create dicom.tfplan without applying it' \
		'  make show-plan            Display the saved Terraform plan' \
		'  make apply                Plan and apply interactively' \
		'  make apply-auto           Plan and apply without confirmation' \
		'  make verify               Test Orthanc REST and DICOMweb' \
		'  make verify-dicom DICOM_FILE=/absolute/test.dcm' \
		'  make get-credentials      Display the Orthanc username and password' \
		'  make configure-bastion    Configure the bastion with Ansible' \
		'  make bastion-status       Test the private stack from the bastion' \
		'  make outputs              Show the non-secret deployment summary' \
		'  make destroy              Plan and destroy with confirmation' \
		'  make destroy-auto         Destroy without confirmation' \
		'' \
		'Optional overrides:' \
		'  TF_ARGS="-var=name=value" PRIVATE_KEY=/absolute/path/to/id_rsa'

init: ## Initialize Terraform providers and backend.
	terraform init

fmt: ## Format all Terraform files.
	terraform fmt -recursive

validate: ## Run all static deployment checks.
	./scripts/validate.sh

plan: ## Create a saved, state-aware Terraform plan.
	./scripts/deploy.sh --plan-only $(TF_ARGS)

show-plan: ## Display the saved Terraform plan.
	@test -f dicom.tfplan || { printf '%s\n' 'dicom.tfplan is missing; run make plan first.' >&2; exit 1; }
	terraform show dicom.tfplan

apply: ## Plan, apply interactively, and configure the bastion.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	BASTION_SSH_PRIVATE_KEY_FILE="$(PRIVATE_KEY)" ./scripts/deploy.sh $(TF_ARGS)

apply-auto: ## Plan and apply without confirmation, then configure the bastion.
	@test -f "$(PRIVATE_KEY)" || { printf 'Private SSH key not found: %s\n' "$(PRIVATE_KEY)" >&2; exit 1; }
	BASTION_SSH_PRIVATE_KEY_FILE="$(PRIVATE_KEY)" ./scripts/deploy.sh --auto-approve $(TF_ARGS)

outputs: ## Show the non-secret deployment summary.
	terraform output deployment_summary

verify: ## Check public Orthanc REST and DICOMweb endpoints.
	./scripts/verify.sh

verify-dicom: ## Upload one non-production DICOM instance and verify it.
	@test -n "$(DICOM_FILE)" || { printf '%s\n' 'Set DICOM_FILE=/absolute/path/to/test.dcm.' >&2; exit 1; }
	./scripts/verify.sh --dicom "$(DICOM_FILE)"

get-credentials: ## Display the sensitive Orthanc login credentials.
	@printf 'Username: '
	@terraform output -raw orthanc_username
	@printf '\nPassword: '
	@terraform output -raw orthanc_password
	@printf '\n'

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
