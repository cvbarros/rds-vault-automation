provider "aws" {
  region = "eu-west-1"

  assume_role {
    role_arn     = "arn:aws:iam::643114976856:role/development"
    session_name = "terraform-session"
  }
}

provider "vault" {}

resource "random_string" "db_password" {
  length  = 30
  special = false
}

data "aws_vpc" "vault-vpc" {
  cidr_block = "10.139.0.0/16"
}

data "aws_subnet_ids" "vault_private_subnet_ids" {
  vpc_id = "${data.aws_vpc.vault-vpc.id}"

  tags {
    Tier = "private"
  }
}

resource "aws_security_group" "sg_db" {
  name        = "sg_vault_db_test"
  description = "Configure traffic for Vault Test DB"
  vpc_id      = "${data.aws_vpc.vault-vpc.id}"

  ingress {
    from_port   = 0
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

module "db" {
  source = "terraform-aws-modules/rds/aws"

  identifier = "vault-db-test"

  engine            = "mariadb"
  engine_version    = "10.2.11"
  instance_class    = "db.t2.micro"
  allocated_storage = 5

  name     = "vaultdb"
  username = "root"
  password = "${random_string.db_password.result}"
  port     = "3306"

  #   create_db_subnet_group    = false
  create_db_option_group    = false
  create_db_parameter_group = false

  #   db_subnet_group_name = "${aws_db_subnet_group.default.id}"

  subnet_ids             = ["${data.aws_subnet_ids.vault_private_subnet_ids.ids}"]
  vpc_security_group_ids = ["${aws_security_group.sg_db.id}"]
  maintenance_window     = "Mon:00:00-Mon:03:00"
  backup_window          = "03:00-06:00"
  tags {
    AppGroup = "vault-db-test"
  }
}

resource "vault_mount" "db" {
  path = "database"
  type = "database"
}

resource "vault_database_secret_backend_connection" "vaultdb" {
  backend = "${vault_mount.db.path}"
  name    = "vaultdb_connection"

  allowed_roles = ["*"]

  mysql {
    connection_url = "root:${random_string.db_password.result}@tcp(${module.db.this_db_instance_address}:3306)/"
  }
}

resource "vault_database_secret_backend_role" "role" {
  backend             = "${vault_mount.db.path}"
  name                = "app"
  db_name             = "${vault_database_secret_backend_connection.vaultdb.name}"
  creation_statements = "CREATE USER '{{name}}'@'%' IDENTIFIED BY '{{password}}';GRANT SELECT ON *.* TO '{{name}}'@'%';"
}
