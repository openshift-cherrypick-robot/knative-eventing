#!/usr/bin/env bash

if [[ -n "${ARTIFACT_DIR:-}" ]]; then
  BUILD_NUMBER=${BUILD_NUMBER:-$(head -c 128 < /dev/urandom | base64 | fold -w 8 | head -n 1)}
  ARTIFACTS="${ARTIFACT_DIR}/build-${BUILD_NUMBER}"
  export ARTIFACTS
  mkdir -p "${ARTIFACTS}"
fi

export EVENTING_NAMESPACE="${EVENTING_NAMESPACE:-knative-eventing}"
export SYSTEM_NAMESPACE=$EVENTING_NAMESPACE
export ZIPKIN_NAMESPACE=$EVENTING_NAMESPACE
export KNATIVE_DEFAULT_NAMESPACE=$EVENTING_NAMESPACE
export CONFIG_TRACING_CONFIG="test/config/config-tracing.yaml"
export EVENTING_TEST_IMAGE_TEMPLATE=$(cat <<-END
{{- with .Name }}
{{- if eq . "event-flaker"}}$KNATIVE_EVENTING_TEST_EVENT_FLAKER{{end -}}
{{- if eq . "event-library"}}$KNATIVE_EVENTING_TEST_EVENT_LIBRARY{{end -}}
{{- if eq . "event-sender"}}$KNATIVE_EVENTING_TEST_EVENT_SENDER{{end -}}
{{- if eq . "eventshub"}}$KNATIVE_EVENTING_TEST_EVENTSHUB{{end -}}
{{- if eq . "heartbeats"}}$KNATIVE_EVENTING_TEST_HEARTBEATS{{end -}}
{{- if eq . "performance"}}$KNATIVE_EVENTING_TEST_PERFORMANCE{{end -}}
{{- if eq . "print"}}$KNATIVE_EVENTING_TEST_PRINT{{end -}}
{{- if eq . "recordevents"}}$KNATIVE_EVENTING_TEST_RECORDEVENTS{{end -}}
{{- if eq . "request-sender"}}$KNATIVE_EVENTING_TEST_REQUEST_SENDER{{end -}}
{{- if eq . "wathola-fetcher"}}$KNATIVE_EVENTING_TEST_WATHOLA_FETCHER{{end -}}
{{- if eq . "wathola-forwarder"}}$KNATIVE_EVENTING_TEST_WATHOLA_FORWARDER{{end -}}
{{- if eq . "wathola-receiver"}}$KNATIVE_EVENTING_TEST_WATHOLA_RECEIVER{{end -}}
{{- if eq . "wathola-sender"}}$KNATIVE_EVENTING_TEST_WATHOLA_SENDER{{end -}}
{{end -}}
END
)

function scale_up_workers(){
  local cluster_api_ns="openshift-machine-api"

  oc get machineset -n ${cluster_api_ns} --show-labels

  # Get the name of the first machineset that has at least 1 replica
  local machineset
  machineset=$(oc get machineset -n ${cluster_api_ns} -o custom-columns="name:{.metadata.name},replicas:{.spec.replicas}" | grep " 1" | head -n 1 | awk '{print $1}')
  # Bump the number of replicas to 6 (+ 1 + 1 == 8 workers)
  oc patch machineset -n ${cluster_api_ns} "${machineset}" -p '{"spec":{"replicas":6}}' --type=merge
  wait_until_machineset_scales_up ${cluster_api_ns} "${machineset}" 6
}

# Waits until the machineset in the given namespaces scales up to the
# desired number of replicas
# Parameters: $1 - namespace
#             $2 - machineset name
#             $3 - desired number of replicas
function wait_until_machineset_scales_up() {
  echo -n "Waiting until machineset $2 in namespace $1 scales up to $3 replicas"
  for _ in {1..150}; do  # timeout after 15 minutes
    local available
    available=$(oc get machineset -n "$1" "$2" -o jsonpath="{.status.availableReplicas}")
    if [[ ${available} -eq $3 ]]; then
      echo -e "\nMachineSet $2 in namespace $1 successfully scaled up to $3 replicas"
      return 0
    fi
    echo -n "."
    sleep 6
  done
  echo - "Error: timeout waiting for machineset $2 in namespace $1 to scale up to $3 replicas"
  return 1
}

# Loops until duration (car) is exceeded or command (cdr) returns non-zero
function timeout_non_zero() {
  SECONDS=0; TIMEOUT=$1; shift
  while eval $*; do
    sleep 5
    [[ $SECONDS -gt $TIMEOUT ]] && echo "ERROR: Timed out" && return 1
  done
  return 0
}

function install_tracing {
  deploy_zipkin
  enable_eventing_tracing
}

function deploy_zipkin {
  logger.info "Installing Zipkin in namespace ${ZIPKIN_NAMESPACE}"
  cat <<EOF | oc apply -f - || return $?
apiVersion: v1
kind: Service
metadata:
  name: zipkin
  namespace: ${ZIPKIN_NAMESPACE}
spec:
  type: NodePort
  ports:
  - name: http
    port: 9411
  selector:
    app: zipkin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: zipkin
  namespace: ${ZIPKIN_NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: zipkin
  template:
    metadata:
      labels:
        app: zipkin
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
      - name: zipkin
        image: ghcr.io/openzipkin/zipkin:2
        ports:
        - containerPort: 9411
        env:
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.namespace
        resources:
          limits:
            memory: 1000Mi
          requests:
            memory: 256Mi
---
EOF

  logger.info "Waiting until Zipkin is available"
  kubectl wait deployment --all --timeout=600s --for=condition=Available -n ${ZIPKIN_NAMESPACE} || return 1
}

function enable_eventing_tracing {
  logger.info "Configuring tracing for Eventing"

  cat <<EOF | oc apply -f - || return $?
apiVersion: v1
kind: ConfigMap
metadata:
  name: config-tracing
  namespace: ${EVENTING_NAMESPACE}
data:
  enable: "true"
  zipkin-endpoint: "http://zipkin.${ZIPKIN_NAMESPACE}.svc.cluster.local:9411/api/v2/spans"
  sample-rate: "1.0"
  debug: "true"
EOF
}

function configure_sugar_controller_testing {
 oc apply -f test/config/sugar.yaml
}

function install_serverless(){
  header "Installing Serverless Operator"
  local operator_dir=/tmp/serverless-operator
  local failed=0
  git clone --branch main https://github.com/openshift-knative/serverless-operator.git $operator_dir
  # unset OPENSHIFT_BUILD_NAMESPACE (old CI) and OPENSHIFT_CI (new CI) as its used in serverless-operator's CI
  # environment as a switch to use CI built images, we want pre-built images of k-s-o and k-o-i
  unset OPENSHIFT_BUILD_NAMESPACE
  unset OPENSHIFT_CI
  pushd $operator_dir
  INSTALL_EVENTING="false" ./hack/install.sh && header "Serverless Operator installed successfully" || failed=1
  popd
  return $failed
}

function install_knative_eventing(){
  header "Installing Knative Eventing"

  cat openshift/release/knative-eventing-ci.yaml > ci
  cat openshift/release/knative-eventing-mtbroker-ci.yaml >> ci

  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-controller|${KNATIVE_EVENTING_CONTROLLER}|g"                               ci
  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-mtping|${KNATIVE_EVENTING_MTPING}|g"                                       ci
  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-apiserver-receive-adapter|${KNATIVE_EVENTING_APISERVER_RECEIVE_ADAPTER}|g" ci
  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-webhook|${KNATIVE_EVENTING_WEBHOOK}|g"                                     ci
  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-channel-controller|${KNATIVE_EVENTING_CHANNEL_CONTROLLER}|g"               ci
  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-channel-dispatcher|${KNATIVE_EVENTING_CHANNEL_DISPATCHER}|g"               ci
  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-mtbroker-ingress|${KNATIVE_EVENTING_MTBROKER_INGRESS}|g"                   ci
  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-mtbroker-filter|${KNATIVE_EVENTING_MTBROKER_FILTER}|g"                     ci
  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-mtchannel-broker|${KNATIVE_EVENTING_MTCHANNEL_BROKER}|g"                   ci

  oc apply -f ci || return 1
  rm ci

  # Wait for 5 pods to appear first
  timeout_non_zero 900 '[[ $(oc get pods -n $EVENTING_NAMESPACE --no-headers | wc -l) -lt 5 ]]' || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 1

  # Apply the testing config for the sugar controller
  configure_sugar_controller_testing

  # Assert that there are no images used that are not CI images (which should all be using the $INTERNAL_REGISTRY)
  # (except for the knative-eventing-operator)
  #oc get pod -n knative-eventing -o yaml | grep image: | grep -v knative-eventing-operator | grep -v ${INTERNAL_REGISTRY} && return 1 || true
}

function uninstall_knative_eventing(){
  header "Uninstalling Knative Eventing"

  cat openshift/release/knative-eventing-ci.yaml > ci
  cat openshift/release/knative-eventing-mtbroker-ci.yaml >> ci

  oc delete -f ci --ignore-not-found=true || return 1
  rm ci
}

function run_e2e_rekt_tests(){
  header "Running E2E Reconciler Tests"
  oc get ns ${SYSTEM_NAMESPACE} 2>/dev/null || SYSTEM_NAMESPACE="knative-eventing"
  sed "s/namespace: ${KNATIVE_DEFAULT_NAMESPACE}/namespace: ${SYSTEM_NAMESPACE}/g" ${CONFIG_TRACING_CONFIG} | oc replace -f -

  oc -n knative-eventing set env deployment/mt-broker-controller BROKER_INJECTION_DEFAULT=true || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 2

  echo "Replacing images used in Rekt test resources with the images built in CI"

  echo "Replacing knative-eventing-test-event-library image"
  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-test-event-library|${KNATIVE_EVENTING_TEST_EVENT_LIBRARY}|g" "$(dirname "$0")/../test/rekt/resources/eventlibrary/eventlibrary.yaml"

  echo "Replacing knative-eventing-test-heartbeats image"
  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-test-heartbeats|${KNATIVE_EVENTING_TEST_HEARTBEATS}|g" "$(dirname "$0")/../test/rekt/resources/containersource/containersource.yaml"

  echo "Replacing knative-eventing-test-event-flaker image"
  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-test-event-flaker|${KNATIVE_EVENTING_TEST_EVENT_FLAKER}|g" "$(dirname "$0")/../test/rekt/resources/flaker/flaker.yaml"

  echo "Replacing knative-eventing-test-eventshub image"
  sed -i -e "s|registry.ci.openshift.org/openshift/knative-.*:knative-eventing-test-eventshub|${KNATIVE_EVENTING_TEST_EVENTSHUB}|g" "$(dirname "$0")/../vendor/knative.dev/reconciler-test/pkg/eventshub/103-pod.yaml"

  go_test_e2e -timeout=1h -parallel=20 ./test/rekt || failed=$?

  # Wait for all test namespaces to be deleted.
  timeout_non_zero 300 '[[ $(oc get project | grep -c test-) -gt 0 ]]' || return 1

  return $failed
}

function run_e2e_tests(){
  header "Running E2E tests with Multi Tenant Channel Based Broker"
  oc get ns ${SYSTEM_NAMESPACE} 2>/dev/null || SYSTEM_NAMESPACE="knative-eventing"
  sed "s/namespace: ${KNATIVE_DEFAULT_NAMESPACE}/namespace: ${SYSTEM_NAMESPACE}/g" ${CONFIG_TRACING_CONFIG} | oc replace -f -
  local test_name="${1:-}"
  local run_command=""
  local failed=0
  local channels=messaging.knative.dev/v1:Channel,messaging.knative.dev/v1:InMemoryChannel
  local sources=sources.knative.dev/v1beta2:PingSource,sources.knative.dev/v1:ApiServerSource,sources.knative.dev/v1:ContainerSource

  local common_opts=" -channels=$channels -sources=$sources --kubeconfig $KUBECONFIG"
  if [ -n "$test_name" ]; then
      local run_command="-run ^(${test_name})$"
  fi

  oc -n knative-eventing set env deployment/mt-broker-controller BROKER_INJECTION_DEFAULT=true || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 2

  go_test_e2e -timeout=50m -parallel=20 ./test/e2e \
    "$run_command" \
    -brokerclass=MTChannelBasedBroker \
    -imagetemplate="$TEST_IMAGE_TEMPLATE" \
    $common_opts || failed=$?

  return $failed
}

function run_conformance_tests(){
  header "Running Conformance tests with Multi Tenant Channel Based Broker"
  oc get ns ${SYSTEM_NAMESPACE} 2>/dev/null || SYSTEM_NAMESPACE="knative-eventing"
  sed "s/namespace: ${KNATIVE_DEFAULT_NAMESPACE}/namespace: ${SYSTEM_NAMESPACE}/g" ${CONFIG_TRACING_CONFIG} | oc replace -f -
  local test_name="${1:-}"
  local run_command=""
  local failed=0
  local channels=messaging.knative.dev/v1:Channel,messaging.knative.dev/v1:InMemoryChannel
  local sources=sources.knative.dev/v1beta2:PingSource,sources.knative.dev/v1:ApiServerSource,sources.knative.dev/v1:ContainerSource

  local common_opts=" -channels=$channels -sources=$sources --kubeconfig $KUBECONFIG"
  if [ -n "$test_name" ]; then
      local run_command="-run ^(${test_name})$"
  fi

  oc -n knative-eventing set env deployment/mt-broker-controller BROKER_INJECTION_DEFAULT=true || return 1
  wait_until_pods_running $EVENTING_NAMESPACE || return 2

  go_test_e2e -timeout=30m -parallel=12 ./test/conformance \
    "$run_command" \
    -brokerclass=MTChannelBasedBroker \
    -imagetemplate="$TEST_IMAGE_TEMPLATE" \
    $common_opts || failed=$?

  return $failed
}
