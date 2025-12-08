# One-liner to patch all Deployments, StatefulSets, and DaemonSets
TOLERATION_PATCH='[{"key":"eks-pvtci-generic-amd64","operator":"Exists","effect":"NoSchedule"}]' && \
for resource in deployments statefulsets daemonsets; do \
  for item in $(kubectl get $resource -n onelens-agent -o name 2>/dev/null); do \
    kubectl patch $item -n onelens-agent --type='json' -p="[{\"op\":\"add\",\"path\":\"/spec/template/spec/tolerations\",\"value\":${TOLERATION_PATCH}}]" 2>/dev/null || \
    kubectl patch $item -n onelens-agent --type='json' -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/tolerations\",\"value\":${TOLERATION_PATCH}}]"; \
  done; \
done && echo "All resources patched successfully!"



