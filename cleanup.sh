#!/bin/bash

declare -a cleanupARR
declare -a cleanupLBARR

aws ec2 describe-instances --filter Name=instance-state-code,Values=16 --output table | grep InstanceId | sed "s/|//g" | tr -d ' ' | sed "s/InstanceId//g"

mapfile -t cleanupARR < <(aws ec2 describe-instances --filter Name=instance-state-code,Values=16 --output table | grep InstanceId | sed "s/|//g" | tr -d ' ' | sed "s/InstanceId//g")

echo "the output is ${cleanupARR[@]}"

aws ec2 terminate-instances --instance-ids ${cleanupARR[@]} 


echo "Cleaning up existing Load Balancers"
mapfile -t cleanupLBARR < <(aws elb describe-load-balancers --output json | grep LoadBalancerName | sed "s/[\"\:\, ]//g" | sed "s/LoadBalancerName//g")

echo "The LBs are ${cleanupLBARR[@]}"

LENGTH=${#cleanupLBARR[@]}
echo "ARRAY LENGTH IS $LENGTH"
for (( i=0; i<${LENGTH}; i++)); 
  do
  aws elb delete-load-balancer --load-balancer-name ${cleanupLBARR[i]} --output text
  sleep 1
done

LAUNCHCONF=(`aws autoscaling describe-launch-configurations --output json | grep LaunchConfigurationName | sed "s/[\"\:\, ]//g" | sed "s/LaunchConfigurationName//g"`)

SCALENAME=(`aws autoscaling describe-auto-scaling-groups --output json | grep AutoScalingGroupName | sed "s/[\"\:\, ]//g" | sed "s/AutoScalingGroupName//g"`)

echo "The asgs are: " ${SCALENAME[@]}
echo "the number is: " ${#SCALENAME[@]}

aws ec2 wait instance-terminated --instance-ids ${cleanupARR[@]}
echo "${cleanupARR[@]} instances terminated"

if [ ${#SCALENAME[@]} -gt 0 ]
  then
echo "SCALING GROUPS to delete..."
#aws autoscaling detach-launch-.

aws autoscaling update-auto-scaling-group --auto-scaling-group-name $SCALENAME --min-size 0 --max-size 0 --desired-capacity 0

aws autoscaling  disable-metrics-collection --auto-scaling-group-name $SCALENAME
sleep 10

aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $SCALENAME --force-delete
sleep 5

aws autoscaling delete-launch-configuration --launch-configuration-name $LAUNCHCONF

#aws autoscaling update-auto-scaling-group --auto-scaling-group-name $SCALENAME --min-size 0 --max-size 0 --desired-capacity 0

#aws autoscaling delete-auto-scaling-group --auto-scaling-group-name $SCALENAME
#aws autoscaling delete-launch-configuration --launch-configuration-name $LAUNCHCONF
fi

mapfile -t dbInstanceARR < <(aws rds describe-db-instances --output json | grep "\"DBInstanceIdentifier" | sed "s/[\"\:\, ]//g" | sed "s/DBInstanceIdentifier//g" )

if [ ${#dbInstanceARR[@]} -gt 0 ]
   then
   echo "Deleting existing RDS database-instances"
   LENGTH=${#dbInstanceARR[@]}

      for (( i=0; i<${LENGTH}; i++));
      do
      if [ ${dbInstanceARR[i]} == "mp1-sg" ];then  
        echo "DB Exists"
        aws rds delete-db-instance --db-instance-identifier mp1-sg --skip-final-snapshot
        aws rds wait db-instance-deleted --db-instance-identifier mp1-sg
        echo "DB Deleted"
      fi  
     done
fi

echo "All done"

