#!/bin/bash

CLUSTER_NAME="ShellTest"
ACCOUNT_ID=" -- TO DO -- ADD AWS ACCOUNT HERE --"

#
# Create EKS cluster with managed, on-demand node group
#
echo "Creating cluster and managed, on-demand node group..."
eksctl create cluster \
  --name=${CLUSTER_NAME} \
  --instance-types=m5.xlarge,m5a.xlarge,m5d.xlarge \
  --managed \
  --nodes=3 \
  --asg-access \
  --with-oidc \
  --nodegroup-name on-demand-4vcpu-16gb

#
# Fetch available instance types for Spot Instances
#
echo "Gathering availaable spot instance types ..."
SPOT_TYPES=$(ec2-instance-selector --vcpus=4 --memory=16 --cpu-architecture=x86_64 --gpus=0 --burst-support=false | awk -vORS=, '{ print $1 }' | sed 's/,$//')

#
# Create additional nodegroup of managed spot instances
#
echo "Adding spot-instance node group to the EKS cluster ..."
eksctl create nodegroup --cluster ${CLUSTER_NAME} \
  --instance-types ${SPOT_TYPES} \
  --managed \
  --spot \
  --name spot-4vcpu-16gb \
  --asg-access \
  --nodes-max 20

# 
# Create IAM policy allowing the autoscaler access to auto-scaling group information
# NOTE: Comment this out if another cluster has already created this policy
#
echo "Checking for Autoscaler Policy in IAM ..."
POLICY=$(aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/AmazonEKSClusterAutoscalerPolicy)
if [ -z "$POLICY" ]; then
  aws iam create-policy \
    --policy-name AmazonEKSClusterAutoscalerPolicy \
    --policy-document file://cluster-autoscaler-policy.json
  echo "Policy created."
else
  echo "Policy already exists. Skipping."
fi

#
# Create a role for the autoscaler to assume
#
echo "Creating IAM Service Account in the EKS Cluster"
eksctl create iamserviceaccount \
  --cluster=${CLUSTER_NAME} \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --attach-policy-arn=arn:aws:iam::${ACCOUNT_ID}:policy/AmazonEKSClusterAutoscalerPolicy \
  --override-existing-serviceaccounts \
  --approve

#
# Deploy the autoscaler
#
echo "Deploying and configuring the Cluster Autoscaler..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/master/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml
echo "Whew. Taking a breath ..."
sleep 15
echo "Patching autoscaler..."
kubectl patch deployment cluster-autoscaler \
  -n kube-system \
  -p '{"spec":{"template":{"metadata":{"annotations":{"cluster-autoscaler.kubernetes.io/safe-to-evict": "false"}}}}}'

#
# Create EFS for the cluster and connect security group
#
echo "Creating EFS for the Cluster..."
VPC_ID=$(aws eks describe-cluster --name ${CLUSTER_NAME} --query "cluster.resourcesVpcConfig.vpcId" --output text)
VPC_CIDR_BLOCK=$(aws ec2 describe-vpcs --vpc-ids ${VPC_ID} --query "Vpcs[].CidrBlock" --output text)
MOUNT_TARGET_SG_NAME="${CLUSTER_NAME}-efs-sg"
MOUNT_TARGET_SG_DESC="NFS Access to EFS from EKS Worker Nodes"
SG_ID=$(aws ec2 create-security-group --group-name ${MOUNT_TARGET_SG_NAME} --description "${MOUNT_TARGET_SG_DESC}" --vpc-id ${VPC_ID} | jq --raw-output '.GroupId')
aws ec2 authorize-security-group-ingress --group-id ${SG_ID} --protocol tcp --port 2049 --cidr ${VPC_CIDR_BLOCK}
FSID=$(aws efs create-file-system --creation-token=${CLUSTER_NAME}-eks-efs | jq --raw-output '.FileSystemId')

# Wait for the EFS to be available
echo "Waiting for the EFS to be ready ..."
while [ ! $(aws efs describe-file-systems --file-system-id ${FSID}| jq --raw-output '.FileSystems[].LifeCycleState') == 'available' ];
do
  sleep 5
done
echo "EFS ${FSID} created and ready."

echo "Associating private subnets with the EFS..."
echo "#!/bin/bash" > delete${CLUSTER_NAME}Cluster.sh

# Iterate through the subnets associated with the cluster
TAG1=tag:kubernetes.io/cluster/$CLUSTER_NAME
TAG2=tag:kubernetes.io/role/internal-elb
subnets=($(aws ec2 describe-subnets --filters "Name=$TAG1,Values=shared" "Name=$TAG2,Values=1" | jq --raw-output '.Subnets[].SubnetId'))
for subnet in ${subnets[@]}
do
    echo "creating mount target in " $subnet
    aws efs create-mount-target --file-system-id $FSID --subnet-id $subnet --security-groups $SG_ID
done

# Unmounting File System
echo "Writing custom deleteCluster script ..."
echo "targets=\$(aws efs describe-mount-targets --file-system-id ${FSID} | jq --raw-output '.MountTargets[].MountTargetId')" >> delete${CLUSTER_NAME}Cluster.sh
echo "for target in \${targets[@]}" >> delete${CLUSTER_NAME}Cluster.sh
echo "do" >> delete${CLUSTER_NAME}Cluster.sh
echo "    echo 'deleting mount target ' \$target" >> delete${CLUSTER_NAME}Cluster.sh
echo "    aws efs delete-mount-target --mount-target-id \$target" >> delete${CLUSTER_NAME}Cluster.sh
echo "done" >> delete${CLUSTER_NAME}Cluster.sh
echo "MOUNTS=\$(aws efs describe-mount-targets --file-system-id ${FSID} | jq --raw-output '.MountTargets[].MountTargetId')" >> delete${CLUSTER_NAME}Cluster.sh
echo "if [ -z \"\$MOUNTS\" ]; then echo \"Mounts are gone and we should not loop.\"; fi" >> delete${CLUSTER_NAME}Cluster.sh
echo "while [ ! -z \"\$MOUNTS\" ]" >> delete${CLUSTER_NAME}Cluster.sh
echo "do" >> delete${CLUSTER_NAME}Cluster.sh
echo "  echo \"Mounts remain. (\$MOUNTS) In loop, sleeping for a bit.\"" >> delete${CLUSTER_NAME}Cluster.sh
echo "  sleep 5" >> delete${CLUSTER_NAME}Cluster.sh
echo "  MOUNTS=\$(aws efs describe-mount-targets --file-system-id ${FSID} | jq --raw-output '.MountTargets[].MountTargetId')" >> delete${CLUSTER_NAME}Cluster.sh
echo "  if [ -z \"\$MOUNTS\" ]; then " >> delete${CLUSTER_NAME}Cluster.sh
echo "    echo \"Mounts are gone and we should exit\"" >> delete${CLUSTER_NAME}Cluster.sh
echo "  else" >> delete${CLUSTER_NAME}Cluster.sh
echo "    echo \"looping\"" >> delete${CLUSTER_NAME}Cluster.sh
echo "  fi" >> delete${CLUSTER_NAME}Cluster.sh
echo "done" >> delete${CLUSTER_NAME}Cluster.sh
echo "echo \"Deleting file system ...\"" >> delete${CLUSTER_NAME}Cluster.sh
echo "aws efs delete-file-system --file-system-id ${FSID}" >> delete${CLUSTER_NAME}Cluster.sh
echo "sleep 10" >> delete${CLUSTER_NAME}Cluster.sh
echo "echo \"Deleting mount security group...\"" >> delete${CLUSTER_NAME}Cluster.sh
echo "aws ec2 delete-security-group --group-id ${SG_ID}" >> delete${CLUSTER_NAME}Cluster.sh
echo "eksctl delete cluster ${CLUSTER_NAME}" >> delete${CLUSTER_NAME}Cluster.sh

#
# Installing the EFS driver for the EKS cluster
#
echo "Installing the EFS CSI driver ..."
helm repo add aws-efs-csi-driver https://kubernetes-sigs.github.io/aws-efs-csi-driver/
helm install aws-efs-csi-driver aws-efs-csi-driver/aws-efs-csi-driver

echo "All done with the automated stuff!!"
echo " "
echo "NOTE: You need to complete the autoscaler configuration by hand. See instructions for 'Deploy the Autoscaler'"
echo "      in the AWS documentation at https://docs.aws.amazon.com/eks/latest/userguide/cluster-autoscaler.html#ca-deploy"
echo "      Start at step 4. "
echo " "
echo "      You will ALSO need to update any of the security, like the configmap/aws-auth if you need others to have"
echo "      access to the cluster."
