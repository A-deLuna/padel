# Substitute with your own
ECR_ID=""
aws ecr get-login-password --region us-west-1 | docker login --username AWS --password-stdin $ECR_ID.dkr.ecr.us-west-1.amazonaws.com

docker build -t padel-ruby-lambda --platform=linux/amd64 .

docker tag padel-ruby-lambda:latest $ECR_ID.dkr.ecr.us-west-1.amazonaws.com/padel-ruby-lambda:latest

docker push $ECR_ID.dkr.ecr.us-west-1.amazonaws.com/padel-ruby-lambda:latest

aws lambda update-function-code --function-name padel-booking --image-uri $ECR_ID.dkr.ecr.us-west-1.amazonaws.com/padel-ruby-lambda:latest

