#!/usr/bin/env bash
set -e

export APPLICATION="vivk8s"

local_container_registry() {

    docker volume create local_registry > /dev/null
    {
        docker container run -d \
        --name registry.localhost \
        -v local_registry:/var/lib/registry \
        --restart always -p 5000:5000 \
        registry:2

        docker container run -d \
        --name proxy-registry.localhost \
        -v `pwd`/config.yaml:/etc/docker/registry/config.yml \
        -v local_registry:/var/lib/registry \
        --restart always -p 5001:5001 \
        registry:2

        docker network create ${APPLICATION}-k3d
        docker network connect ${APPLICATION}-k3d registry.localhost
        docker network connect ${APPLICATION}-k3d proxy-registry.localhost
    } ||{
        echo "docker registry already exists"
    }
}

local_clear() {
    set +e
    local_down
    docker network rm ${APPLICATION}-k3d
    docker volume rm local_registry
    rm tls.key tls.crt
}

local_up() {

    k3d cluster create ${APPLICATION}-k3d \
      -v `pwd`/registries.yaml:/etc/rancher/k3s/registries.yaml \
      --k3s-server-arg "--disable=metrics-server" \
      --k3s-server-arg "--disable=traefik" \
      -p 80:80@loadbalancer \
      -p 443:443@loadbalancer \
      --agents 3 \
      --servers 1

    local_container_registry

    echo "Waiting for cluster to finish coming up"
    while ! (kubectl get node | grep "agent" > /dev/null); do sleep 3; done
    kubectl wait --for=condition=available --timeout 600s -A deployment --all > /dev/null
    kubectl wait --for=condition=ready --timeout 600s -A pods --all --field-selector status.phase=Running > /dev/null
}

argocd () {
    ARGOCD_PATH=vendor/argocd
    helm dependency update "${ARGOCD_PATH}" --skip-refresh
    helm upgrade argocd "${ARGOCD_PATH}" -i --create-namespace -f "cluster/argocd/values.yaml" -f "cluster/argocd/dev-values.yaml" -n argocd --wait --timeout 10m
    kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server -o name | cut -d'/' -f 2
}

istio (){

    kubectl create -f vendors/istio/istio.yaml

    # wait until deployment of istio
    sleep 15
    
    kubectl wait --for=condition=Ready pod -l app=istio-ingressgateway -n istio-system
    kubectl wait --for=condition=Ready pod -l app=istiod -n istio-system

    mkcert -key-file tls.key -cert-file tls.crt "*.local"
    kubectl create secret tls istio-ingressgateway-certs -n istio-system --cert=tls.crt --key=tls.key    
    mkcert -install

    # create public gateway
    kubectl create -f vendors/istio/gateway.yaml
}

demo () {

    kubectl apply -f vendors/demo/bookinfo.yaml
    kubectl apply -f vendors/demo/bookinfo-vs.yaml
}

spire () {
    # deploy namespace
    kubectl apply -f vendors/spifee-spire/bases/spire-namespace.yaml 
    
    # deploy prereqs for spire server
    kubectl apply -f vendors/spifee-spire/bases/server-account.yaml 
    kubectl apply -f vendors/spifee-spire/bases/spire-bundle-configmap.yaml 
    kubectl apply -f vendors/spifee-spire/bases/server-cluster-role.yaml 
    
    # deploy spire server
    kubectl apply -f vendors/spifee-spire/bases/server-configmap.yaml 
    kubectl apply -f vendors/spifee-spire/bases/server-statefulset.yaml 
    kubectl apply -f vendors/spifee-spire/bases/server-service.yaml 
    
    sleep 10
    kubectl wait --for=condition=Ready pod -l app=spire-server -n spire
    
    # deploy spire agent prereqs
    kubectl apply -f vendors/spifee-spire/bases/agent-account.yaml 
    kubectl apply -f vendors/spifee-spire/bases/agent-cluster-role.yaml 
    kubectl apply -f vendors/spifee-spire/bases/agent-configmap.yaml 
    
    # deploy spire agent
    kubectl apply -f vendors/spifee-spire/bases/agent-daemonset.yaml 
    
    # wait for creation of agents one per node
    kubectl wait --for=condition=Ready pod -l app=spire-agent -n spire

    # Create a new registration entry for the node, specifying the SPIFFE ID to allocate to the node:
    kubectl exec -n spire spire-server-0 -- /opt/spire/bin/spire-server entry create -spiffeID spiffe://example.org/ns/spire/sa/spire-agent -selector k8s_sat:cluster:${APPLICATION}-k3d -selector k8s_sat:agent_ns:spire -selector k8s_sat:agent_sa:spire-agent -node
    
}

spifee_workload() {
    # Create workload
    kubectl apply -f vendors/spifee-spire/bases/client-deployment.yaml
    
    # Verification to verify svid is assigned to workload or not
    # kubectl exec -it $(kubectl get pods -o=jsonpath='{.items[0].metadata.name}' -l app=client)  -- /bin/sh
    # /opt/spire/bin/spire-agent api fetch -socketPath /run/spire/sockets/agent.sock
    # you should get error access denied

    sleep 10

    # Create a new registration entry for the workload, specifying the SPIFFE ID to allocate to the workload:
    kubectl exec -n spire spire-server-0 -- /opt/spire/bin/spire-server entry create -spiffeID spiffe://example.org/ns/default/sa/default -parentID spiffe://example.org/ns/spire/sa/spire-agent -selector k8s:ns:default -selector k8s:sa:default

    # you can perform above steps for verification again to check.
    # you can see assigned SVID.
}
local_down() {
    {
        k3d cluster delete ${APPLICATION}-k3d 
        docker network disconnect ${APPLICATION}-k3d registry.localhost
        docker network disconnect ${APPLICATION}-k3d proxy-registry.localhost
    } || echo "no cluster exists"
    docker stop registry.localhost > /dev/null
    docker rm registry.localhost > /dev/null
    docker stop proxy-registry.localhost > /dev/null
    docker rm proxy-registry.localhost > /dev/null
}

$1