# Systemd Files

These we extracted from a minikube pod.

```
minikube start \
  --extra-config=apiserver.oidc-issuer-url=https://auth.sk8s.net/ \
  --extra-config=apiserver.oidc-required-claim=azp=CkbKDkUMWwmj4Ebi5GrO7X71LY57QRiU \
  --extra-config=apiserver.oidc-client-id=https://sk8s-co.us.auth0.com/userinfo \
  --nodes=2
```

Then, hop into `minikube-m02` and extract what's needed from `/etc/systemd/system`.
