# code_build spec for pulling source from BitBucket
version: 0.2

env:
  parameter-store:
    USER: "/app/bb_user"  
    PASS: "/app/bb_app_pass"
    CONSUL_URL: "/infra/consul_url"
    CONSUL_HTTP_TOKEN: "/infra/${app_name}-${env_type}/consul_http_token"
    
phases:
  pre_build:
    commands:
      - yum install -y yum-utils
      - yum-config-manager --add-repo https://rpm.releases.hashicorp.com/AmazonLinux/hashicorp.repo
      - yum -y install terraform consul
      - export CONSUL_HTTP_ADDR=https://$CONSUL_URL
      - export MONGODB_ATLAS_PROJECT_ID=$(aws ssm get-parameters --with-decryption --names /infra/${app_name}-${env_type}/mongodb_atlas_project_id --query 'Parameters[].Value' --output text)
      - export MONGODB_ATLAS_PUBLIC_KEY=$(aws ssm get-parameters --with-decryption --names /infra/${app_name}-${env_type}/mongodb_atlas_public_key --query 'Parameters[].Value' --output text)
      - export MONGODB_ATLAS_PRIVATE_KEY=$(aws ssm get-parameters --with-decryption --names /infra/${app_name}-${env_type}/mongodb_atlas_private_key --query 'Parameters[].Value' --output text)
      - export MONGODB_ATLAS_ORG_ID=$(aws ssm get-parameters --with-decryption --names /infra/${app_name}-${env_type}/mongodb_atlas_org_id --query 'Parameters[].Value' --output text)
      - |
        if [ "$DEPLOYMENT_TYPE" != "AppMesh" ]; then
          DEPLOYMENT_DETAILS=$(aws dynamodb get-item --table-name MergeWaiter-${app_name}-${env_type} --key '{"APPLICATION" :{"S":"${app_name}-${env_name}"}}' --attributes-to-get '["Details"]' --query 'Item.Details.L[].M') 
          for row in $(echo "$${DEPLOYMENT_DETAILS}" | jq -r '.[] | @base64'); do
            _jq() {
              echo $${row} | base64 --decode | jq -r $${1}
              }
            DEPLOYMENT_ID=$(_jq '.DeploymentId.S')
            HOOK_EXECUTION_ID=$(_jq '.LifecycleEventHookExecutionId.S')
            aws deploy put-lifecycle-event-hook-execution-status --deployment-id $DEPLOYMENT_ID --lifecycle-event-hook-execution-id $HOOK_EXECUTION_ID --status Succeeded --output text
            DEPLOY_STATUS=$(aws deploy get-deployment --deployment-id $DEPLOYMENT_ID --query 'deploymentInfo.status' --output text)
            if [ "$DEPLOY_STATUS" = "InProgress" ] || [ "$DEPLOY_STATUS" = "Ready" ]; then
              aws deploy continue-deployment --deployment-id $DEPLOYMENT_ID --deployment-wait-type TERMINATION_WAIT
            fi
          done
          aws dynamodb delete-item --table-name MergeWaiter-${app_name}-${env_type} --key '{"APPLICATION" :{"S":"${app_name}-${env_name}"}}'
        fi
  build:
    on-failure: ABORT
    commands:
      - INFRA_CHANGED=$(consul kv get "infra/${app_name}-${env_name}/infra_changed")
      - echo "INFRA_CHANGED =" $INFRA_CHANGED
      - CURRENT_COLOR=$(consul kv get "infra/${app_name}-${env_name}/current_color")
      - echo "CURRENT_COLOR = " $CURRENT_COLOR 
      - |
        if [ "$CURRENT_COLOR" != "green" ] && [ "$CURRENT_COLOR" != "blue" ]; then
          echo "Creating Green route"
          NEXT_COLOR="green"
          CURRENT_COLOR="white"
          CURRENT_RECORD="DUMMY_Blue"
        else 
          echo "switching colors"
          if [[ $CURRENT_COLOR == "green" ]]; then
            NEXT_COLOR="blue"
            CURRENT_COLOR="green"
          else
            NEXT_COLOR="green"
            CURRENT_COLOR="blue"
          fi
        fi
        echo "NEXT_COLOR = " $NEXT_COLOR
        consul kv put "infra/${app_name}-${env_name}/current_color" $NEXT_COLOR
      - |
        # below code applies only if INFRA_CHANGED
        if [ "$INFRA_CHANGED" == "true" ]; then
          consul kv delete "infra/${app_name}-${env_name}/infra_changed"
          echo "Shifting traffic"
          cd $CODEBUILD_SRC_DIR/terraform/shared
          terraform init
          terraform workspace select shared-${env_type}
          terraform init
          terraform apply -target=module.dns -auto-approve || exit 1
          cd $CODEBUILD_SRC_DIR/terraform/app
          terraform init
          if [[ "$CURRENT_COLOR" == "white" ]]; then
            terraform workspace select ${env_name}
          else
            terraform workspace select ${env_name}-$CURRENT_COLOR
          fi
          echo "Waiting ${ttl} seconds for DNS Cache to refresh"
          sleep ${ttl}
          echo "Destroying old environment"
          cd $CODEBUILD_SRC_DIR/terraform/app
          terraform init
          terraform destroy -auto-approve
          terraform workspace select ${env_name}-$NEXT_COLOR
          if [[ "$CURRENT_COLOR" == "white" ]]; then
            terraform workspace delete ${env_name}
          else
            terraform workspace delete ${env_name} || echo "no base workspace to delete"
            terraform workspace delete ${env_name}-$CURRENT_COLOR
          fi
        fi
      - export DEPLOYMENT_TYPE=`aws ssm get-parameter --name "/infra/${app_name}-${env_name}/deployment_type" | jq -r .Parameter.Value `
      - |
        if [ "$DEPLOYMENT_TYPE" == "AppMesh" ]; then
          # --- get value of task token from SSM parameter (which is stored by SF step)
          export TASK_TOKEN=`aws ssm get-parameter --name "/infra/${app_name}-${env_name}/task_token" | jq -r .Parameter.Value `
          echo $TASK_TOKEN
          export FUNCTION_NAME="${app_name}-${env_name}-appmesh-sf-task-token"
          echo $FUNCTION_NAME
          aws lambda invoke --function-name $FUNCTION_NAME --invocation-type Event --payload "{ \"CallerId\":\"CodeBuild\", \"TaskToken\":\"$TASK_TOKEN\", \"StatusCode\":\"200\"  }" /dev/null
        fi
