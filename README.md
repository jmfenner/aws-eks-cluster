# aws-eks-cluster
Create and test EKS cluster with both on-demand and spot node groups and cluster autoscaler. Nginx/ELB ingress controller. Some demo apps.

## Initial Setup of EKS Cluster
Update the createCluster.sh script with your AWS account ID, then run it. It may take upwards of half an hour to run and create the assets. 

The script will create a custom delete script you can use later to tear the cluster down.

Then finish cluster configuration per the notes when the script completes.

## Deploy the Echo Applications and the Ingress Controller
Deploy echo1.yaml, echo2.yaml, and nginx-ingress.yaml (from https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v0.34.1/deploy/static/provider/do/deploy.yaml) 

This will cause an AWS Elastic Load Balancer to be created for the ingress controller. You can then connect DNS A records to it to route traffic, if needed.

You will need to add the following annotation to the service/ingress-nginx-controller (per https://stackoverflow.com/questions/42059664/kubernetes-nginx-ingress-with-proxy-protocol-ended-up-with-broken-header):
```
service.beta.kubernetes.io/aws-load-balancer-proxy-protocol: '*'
```

You can then deploy an ingress for the Echo applications like this:
```
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  name: echo-ingress
spec:
  rules:
  - host: echo1.your-domain-name.com
    http:
      paths:
      - backend:
          serviceName: echo1
          servicePort: 80
  - host: echo2.your-domain-name.com
    http:
      paths:
      - backend:
          serviceName: echo2
          servicePort: 80
```

Be sure to change the host names appropriately.

## Deploy the SSL Certificate Manager and Certificate Issuers
Deploy cert-manager.yaml.

Then update the staging_issuer and prod_issuer files with your e-mail address.

## Update Echo Applications to use SSL
Update the echo ingress to include SSL, as follows:

```
apiVersion: networking.k8s.io/v1beta1
kind: Ingress
metadata:
  name: echo-ingress
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-staging"
spec:
  tls:
  - hosts:
    - echo1.your-domain-name.com
    - echo2.your-domain-name.com
    secretName: echo-tls
  rules:
  - host: echo1.your-domain-name.com
    http:
      paths:
      - backend:
          serviceName: echo1
          servicePort: 80
  - host: echo2.your-domain-name.com
    http:
      paths:
      - backend:
          serviceName: echo2
          servicePort: 80
```

Again, be sure to have the host URLs correct.

You will need to use the letsencrypt-prod certificates in the ingress to avoid having the browser complain.

Once ready, you should be able to test in the browser or through:
```
wget --save-headers -O- echo1.your-domain-name.com
```


