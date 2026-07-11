data "terraform_remote_state" "shared" {
  backend = "local"
  config = {
    path = var.shared_state_path
  }
}

module "tenant" {
  source = "../../modules/tenant"

  tenant_id = var.tenant_id

  aws_region            = data.terraform_remote_state.shared.outputs.aws_region
  vpc_id                = data.terraform_remote_state.shared.outputs.vpc_id
  subnet_ids            = data.terraform_remote_state.shared.outputs.subnet_ids
  rds_subnet_group_name = data.terraform_remote_state.shared.outputs.rds_subnet_group_name
  code_bucket           = data.terraform_remote_state.shared.outputs.code_bucket
  spill_bucket          = data.terraform_remote_state.shared.outputs.spill_bucket
  results_bucket        = data.terraform_remote_state.shared.outputs.results_bucket
  mysql_jar_key         = data.terraform_remote_state.shared.outputs.mysql_jar_key
  dynamodb_catalog_name = data.terraform_remote_state.shared.outputs.dynamodb_catalog_name
  dynamodb_table_prefix = data.terraform_remote_state.shared.outputs.dynamodb_table_prefix
}
