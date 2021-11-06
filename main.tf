provider "aws" {
}

resource "random_id" "id" {
  byte_length = 8
}

resource "aws_iam_role" "appsync" {
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "appsync.amazonaws.com"
      },
      "Effect": "Allow"
    }
  ]
}
EOF
}

resource "aws_dynamodb_table" "group" {
  name         = "group-${random_id.id.hex}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}
resource "aws_dynamodb_table" "user" {
  name         = "user-${random_id.id.hex}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  attribute {
    name = "groupId"
    type = "S"
  }

  global_secondary_index {
    name            = "groupId"
    hash_key        = "groupId"
    projection_type = "ALL"
  }
}

data "aws_iam_policy_document" "appsync" {
  statement {
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:ConditionCheckItem",
    ]
    resources = [
      aws_dynamodb_table.group.arn,
      aws_dynamodb_table.user.arn,
    ]
  }
  statement {
    actions = [
      "dynamodb:Query",
    ]
    resources = [
      "${aws_dynamodb_table.user.arn}/index/groupId",
    ]
  }
}

resource "aws_iam_role_policy" "appsync" {
  role   = aws_iam_role.appsync.id
  policy = data.aws_iam_policy_document.appsync.json
}

resource "aws_appsync_graphql_api" "appsync" {
  name                = "appsync_test"
  schema              = file("schema.graphql")
  authentication_type = "AWS_IAM"
}

resource "aws_appsync_datasource" "ddb_groups" {
  api_id           = aws_appsync_graphql_api.appsync.id
  name             = "ddb_groups"
  service_role_arn = aws_iam_role.appsync.arn
  type             = "AMAZON_DYNAMODB"
  dynamodb_config {
    table_name = aws_dynamodb_table.group.name
  }
}

resource "aws_appsync_datasource" "ddb_users" {
  api_id           = aws_appsync_graphql_api.appsync.id
  name             = "ddb_users"
  service_role_arn = aws_iam_role.appsync.arn
  type             = "AMAZON_DYNAMODB"
  dynamodb_config {
    table_name = aws_dynamodb_table.user.name
  }
}

# resolvers
resource "aws_appsync_resolver" "Query_groupById" {
  api_id            = aws_appsync_graphql_api.appsync.id
  type              = "Query"
  field             = "groupById"
  data_source       = aws_appsync_datasource.ddb_groups.name
  request_template  = <<EOF
{
	"version" : "2018-05-29",
	"operation" : "GetItem",
	"key" : {
		"id" : {"S": $util.toJson($ctx.args.id)}
	},
	"consistentRead" : true
}
EOF
  response_template = <<EOF
#if($ctx.error)
	$util.error($ctx.error.message, $ctx.error.type)
#end
$util.toJson($ctx.result)
EOF
}

resource "aws_appsync_resolver" "Mutation_addGroup" {
  api_id            = aws_appsync_graphql_api.appsync.id
  type              = "Mutation"
  field             = "addGroup"
  data_source       = aws_appsync_datasource.ddb_groups.name
  request_template  = <<EOF
{
	"version" : "2018-05-29",
	"operation" : "PutItem",
	"key" : {
		"id" : {"S": "$util.autoId()"}
	},
	"attributeValues": {
		"name": {"S": $util.toJson($ctx.args.name)}
	}
}
EOF
  response_template = <<EOF
#if($ctx.error)
	$util.error($ctx.error.message, $ctx.error.type)
#end
$util.toJson($ctx.result)
EOF
}

resource "aws_appsync_resolver" "Mutation_addUser" {
  api_id            = aws_appsync_graphql_api.appsync.id
  type              = "Mutation"
  field             = "addUser"
  data_source       = aws_appsync_datasource.ddb_users.name
  request_template  = <<EOF
{
	"version": "2018-05-29",
	"operation": "TransactWriteItems",
	"transactItems": [
		{
			"table": "${aws_dynamodb_table.user.name}",
			"operation": "PutItem",
			"key": {
				"id" : {"S": "$util.autoId()"}
			},
			"attributeValues": {
				"name": {"S": $util.toJson($ctx.args.name)},
				"groupId": {"S": $util.toJson($ctx.args.groupId)}
			}
		},
		{
			"table": "${aws_dynamodb_table.group.name}",
			"operation": "ConditionCheck",
			"key":{
				"id": {"S": $util.toJson($ctx.args.groupId)}
			},
			"condition":{
				"expression": "attribute_exists(#pk)",
				"expressionNames": {
					"#pk": "id"
				}
			}
		}
	]
}
EOF
  response_template = <<EOF
#if($ctx.error)
	$util.error($ctx.error.message, $ctx.error.type)
#end
$util.toJson($ctx.result.keys[0].id)
EOF
}

resource "aws_appsync_resolver" "Group_users" {
  api_id            = aws_appsync_graphql_api.appsync.id
  type              = "Group"
  field             = "users"
  data_source       = aws_appsync_datasource.ddb_users.name
  request_template  = <<EOF
{
	"version" : "2018-05-29",
	"operation" : "Query",
	"index": "groupId",
	"query": {
		"expression" : "#groupId = :groupId",
		"expressionNames": {
			"#groupId": "groupId"
		},
		"expressionValues" : {
			":groupId" : {"S": $util.toJson($ctx.source.id)}
		}
	}
	#if($context.arguments.count)
		,"limit": $util.toJson($ctx.args.count)
	#end
	#if($context.arguments.nextToken)
		,"nextToken": $util.toJson($ctx.args.nextToken)
	#end
}
EOF
  response_template = <<EOF
#if($ctx.error)
	$util.error($ctx.error.message, $ctx.error.type)
#end
{
	"users": $utils.toJson($ctx.result.items)
	#if($ctx.result.nextToken)
		,"nextToken": $util.toJson($ctx.result.nextToken)
	#end
}
EOF
}
