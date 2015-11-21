#!/bin/bash
# This program takes 7 arguments in the following order
# $1 - ami image-id
# $2 - count
# $3 - instance-type
# $4 - security-group-ids
# $5 - subnet-id
# $6 - key-name
# $7 - iam-profile


./cleanup.sh

declare -a EC2INSTANCELIST
ELBNAME=itmo544Elb
LAUNCHCONFIGNAME=itmo544LaunchConfig
AUTOSCALENAME=itmo544ExtendedAutoScalingGroup
DBINSTANCEIDENTIFIER=mp1-sg
DBUSERNAME=sandhyagupta
DBPASSWORD=sandhya987
DBNAME=customerrecords
SNSIMAGEDISPLAYNAME=mp2UploadImages-sg
SNSMETRICSDISPLAYNAME=mp2CloudMetrics-sg
USEREMAILID=shandisand@gmail.com

mapfile -t EC2INSTANCELIST < <(aws ec2 run-instances --image-id $1 --count $2 --instance-type $3 --key-name $6 --security-group-ids $4 --subnet-id $5 --associate-public-ip-address --iam-instance-profile Name=$7 --user-data file://../itmo544-fall2015-environmentRep-2/install-webserver.sh --output table | grep InstanceId |  sed -e "s/|//g" -e "s/ //g" -e "s/InstanceId//g")
echo ${EC2INSTANCELIST[@]}

aws ec2 wait instance-running --instance-ids ${EC2INSTANCELIST[@]}
echo "Instances are running"
echo

#ElasticLoadBalancer
ELBURL=(`aws elb create-load-balancer --load-balancer-name $ELBNAME --listeners Protocol=HTTP,LoadBalancerPort=80,InstanceProtocol=HTTP,InstancePort=80 --subnets $5 --security-groups $4`)
echo "Finished launching elastic load balancer : $ELBURL and sleeping for 25 seconds"
for i in {0..25}; do
	echo -ne '.';
	sleep 1;
done
echo

aws elb register-instances-with-load-balancer --load-balancer-name $ELBNAME --instances ${EC2INSTANCELIST[@]}

aws elb configure-health-check --load-balancer-name $ELBNAME --health-check Target=HTTP:80/index.html,Interval=30,UnhealthyThreshold=2,HealthyThreshold=2,Timeout=3

aws elb create-lb-cookie-stickiness-policy --load-balancer-name $ELBNAME --policy-name my-duration-cookie-policy
aws elb set-load-balancer-policies-of-listener --load-balancer-name $ELBNAME --load-balancer-port 80 --policy-names my-duration-cookie-policy

#aws elb create-app-cookie-stickiness-policy --load-balancer-name $ELBNAME --policy-name gallery-app-cookie-policy --cookie-name gallery-app-cookie
#aws elb set-load-balancer-policies-of-listener --load-balancer-name $ELBNAME --load-balancer-port 80 --policy-names gallery-app-cookie-policy

echo "Waiting for 3 minutes(180 seconds) before opening ELB in web browser"
for i in {0..180}; do
	echo -ne '.';
	sleep 1;
done
echo

#Create an SNS topic for image upload subscriptions
SNSTOPICIMAGEARN=(`aws sns create-topic --name $SNSIMAGEDISPLAYNAME`)
aws sns set-topic-attributes --topic-arn $SNSTOPICIMAGEARN --attribute-name DisplayName --attribute-value $SNSIMAGEDISPLAYNAME    

#Create an SNS topic for cloud watch metrics subscriptions
SNSTOPICMETRICSARN=(`aws sns create-topic --name $SNSMETRICSDISPLAYNAME`)
aws sns set-topic-attributes --topic-arn $SNSTOPICMETRICSARN --attribute-name DisplayName --attribute-value $SNSMETRICSDISPLAYNAME

#Subscribing the user to the cloud watch metrics topic
aws sns subscribe --topic-arn $SNSTOPICMETRICSARN --protocol email --notification-endpoint $USEREMAILID

aws autoscaling create-launch-configuration --launch-configuration-name $LAUNCHCONFIGNAME --image-id $1 --key-name $6 --security-groups $4 --instance-type $3 --user-data file://../itmo544-fall2015-environmentRep/install-webserver.sh --iam-instance-profile $7

aws autoscaling create-auto-scaling-group --auto-scaling-group-name $AUTOSCALENAME --launch-configuration-name $LAUNCHCONFIGNAME --load-balancer-names $ELBNAME --health-check-type ELB --min-size 3 --max-size 6 --desired-capacity 3 --default-cooldown 600 --health-check-grace-period 120 --vpc-zone-identifier $5 

#Increase Group Size Policy
INCREASEARN=(`aws autoscaling put-scaling-policy --policy-name increaseGroupSize --auto-scaling-group-name $AUTOSCALENAME --scaling-adjustment 3 --adjustment-type ChangeInCapacity`)

#Descrase Group Size Policy
DECREASEARN=(`aws autoscaling put-scaling-policy --policy-name decreaseGroupSize --auto-scaling-group-name $AUTOSCALENAME --scaling-adjustment -3 --adjustment-type ChangeInCapacity`)

#Add Capacity Clound Watch Metric Alarm
aws cloudwatch put-metric-alarm --alarm-name cpuGreaterThanEqualTo30 --alarm-description "Alarm when CPU exceeds 30 percent" --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average --period 120 --threshold 30 --comparison-operator GreaterThanOrEqualToThreshold --evaluation-periods 1 --unit Percent --dimensions "Name=AutoScalingGroupName,Value=$AUTOSCALENAME" --alarm-actions $INCREASEARN $SNSTOPICMETRICSARN

#Remove Capacity Cloud Watch Metric Alarm
aws cloudwatch put-metric-alarm --alarm-name cpuLessThanEqualTo10 --alarm-description "Alarm when CPU decreases 10 percent" --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average --period 120 --threshold 10 --comparison-operator LessThanOrEqualToThreshold  --evaluation-periods 1 --unit Percent --dimensions "Name=AutoScalingGroupName,Value=$AUTOSCALENAME" --alarm-actions $DECREASEARN $SNSTOPICMETRICSARN

#Create AWS RDS Instance
aws rds create-db-instance --db-name $DBNAME --db-instance-identifier $DBINSTANCEIDENTIFIER --db-instance-class db.t2.micro --engine MySQL --master-username $DBUSERNAME --master-user-password $DBPASSWORD --allocated-storage 10 --publicly-accessible

#Wait until the DB is created
aws rds wait db-instance-available --db-instance-identifier $DBINSTANCEIDENTIFIER

RDSENDPOINT=(`aws rds describe-db-instances --db-instance-identifier $DBINSTANCEIDENTIFIER --output table | grep Address | sed -e "s/|//g" -e "s/[^ ]* //" -e "s/[^ ]* //" -e "s/[^ ]* //" -e "s/[^ ]* //"`)

#Connect to the database and create a table
cat << EOF | mysql -h $RDSENDPOINT -P 3306 -u $DBUSERNAME -p$DBPASSWORD $DBNAME
CREATE TABLE IF NOT EXISTS userdetails(id INT NOT NULL AUTO_INCREMENT, uname VARCHAR(200) NOT NULL, email VARCHAR(200) NOT NULL, phone VARCHAR(20) NOT NULL, subscription VARCHAR(1) NOT NULL, createdat DATETIME DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(id), UNIQUE KEY(email));
CREATE TABLE IF NOT EXISTS usergallerydetails(id INT NOT NULL AUTO_INCREMENT, userid INT, s3rawurl VARCHAR(255) NOT NULL, s3finishedurl VARCHAR(255) NOT NULL, jpgfilename VARCHAR(255) NOT NULL, status INT NOT NULL, createdat DATETIME DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY(id), FOREIGN KEY (userid) REFERENCES userdetails(id));
CREATE TABLE IF NOT EXISTS snsdetails(snsid INT NOT NULL AUTO_INCREMENT, snsdisplayname VARCHAR(50) NOT NULL, snsarn VARCHAR(255) NOT NULL, PRIMARY KEY(snsid));
INSERT INTO snsdetails (snsdisplayname,snsarn) VALUES ('$SNSIMAGEDISPLAYNAME','$SNSTOPICIMAGEARN');
INSERT INTO snsdetails (snsdisplayname,snsarn) VALUES ('$SNSMETRICSDISPLAYNAME','$SNSTOPICMETRICSARN');
EOF

