#!/bin/bash

branch=${1-'knative-v0.6.0'}
openshift=${2-'4.3'}
promotion_disabled=${3-false}

if [[ "$branch" == "knative-next" ]]; then
    branch="knative-nightly"
fi

core_images=$(find ./openshift/ci-operator/knative-images -mindepth 1 -maxdepth 1 -type d | LC_COLLATE=posix sort)
test_images=$(find ./openshift/ci-operator/knative-test-images -mindepth 1 -maxdepth 1 -type d | LC_COLLATE=posix sort)

function print_image_dependencies {
  for img in $core_images; do
    image_base=knative-eventing-$(basename $img)
    to_image=$(echo ${image_base//[_.]/-})
    to_image=$(echo ${to_image//v0/upgrade-v0})
    to_image=$(echo ${to_image//migrate/storage-version-migration})
    image_env=$(echo ${to_image//-/_})
    image_env=$(echo ${image_env^^})
    cat <<EOF
      - env: $image_env
        name: $to_image
EOF
  done

  for img in $test_images; do
    image_base=knative-eventing-test-$(basename $img)
    to_image=$(echo ${image_base//_/-})
    image_env=$(echo ${to_image//-/_})
    image_env=$(echo ${image_env^^})
    cat <<EOF
      - env: $image_env
        name: $to_image
EOF
  done
}

image_deps=$(print_image_dependencies)

cat <<EOF
tag_specification:
  cluster: https://api.ci.openshift.org
  name: '$openshift'
  namespace: ocp
promotion:
  additional_images:
    knative-eventing-src: src
  disabled: $promotion_disabled
  cluster: https://api.ci.openshift.org
  namespace: openshift
  name: $branch.0
base_images:
  base:
    name: '$openshift'
    namespace: ocp
    tag: base
build_root:
  project_image:
    dockerfile_path: openshift/ci-operator/build-image/Dockerfile
canonical_go_repository: knative.dev/eventing
binary_build_commands: make install
test_binary_build_commands: make test-install
tests:
EOF
if [[ "$openshift" == "4.8" ]]; then
cat <<EOF
- as: e2e-aws-ocp-${openshift//./}
  cluster_claim:
    architecture: amd64
    cloud: aws
    owner: openshift-ci
    product: ocp
    timeout: 1h0m0s
    version: "4.8"
  steps:
    test:
    - as: test
      cli: latest
      commands: make test-e2e
      dependencies:
$image_deps
      from: src
      resources:
        requests:
          cpu: 100m
      timeout: 4h0m0s
    workflow: generic-claim
- as: conformance-aws-ocp-${openshift//./}
  cluster_claim:
    architecture: amd64
    cloud: aws
    owner: openshift-ci
    product: ocp
    timeout: 1h0m0s
    version: "4.8"
  steps:
    test:
    - as: test
      cli: latest
      commands: make test-conformance
      dependencies:
$image_deps
      from: src
      resources:
        requests:
          cpu: 100m
      timeout: 4h0m0s
    workflow: generic-claim
- as: reconciler-aws-ocp-${openshift//./}
  cluster_claim:
    architecture: amd64
    cloud: aws
    owner: openshift-ci
    product: ocp
    timeout: 1h0m0s
    version: "4.8"
  steps:
    test:
    - as: test
      cli: latest
      commands: make test-reconciler
      dependencies:
$image_deps
      from: src
      resources:
        requests:
          cpu: 100m
      timeout: 4h0m0s
    workflow: generic-claim
- as: e2e-aws-ocp-${openshift//./}-continuous
  cluster_claim:
    architecture: amd64
    cloud: aws
    owner: openshift-ci
    product: ocp
    timeout: 1h0m0s
    version: "4.8"
  cron: 0 */12 * * 1-5
  steps:
    test:
    - as: test
      cli: latest
      commands: make test-e2e
      dependencies:
$image_deps
      from: src
      resources:
        requests:
          cpu: 100m
      timeout: 4h0m0s
    workflow: generic-claim
EOF
else
cat <<EOF
- as: e2e-aws-ocp-${openshift//./}
  steps:
    cluster_profile: aws
    test:
    - as: test
      cli: latest
      commands: make test-e2e
      dependencies:
$image_deps
      from: src
      resources:
        requests:
          cpu: 100m
      timeout: 4h0m0s
    workflow: ipi-aws
- as: conformance-aws-ocp-${openshift//./}
  steps:
    cluster_profile: aws
    test:
    - as: test
      cli: latest
      commands: make test-conformance
      dependencies:
$image_deps
      from: src
      resources:
        requests:
          cpu: 100m
      timeout: 4h0m0s
    workflow: ipi-aws
- as: reconciler-aws-ocp-${openshift//./}
  steps:
    cluster_profile: aws
    test:
    - as: test
      cli: latest
      commands: make test-reconciler
      dependencies:
$image_deps
      from: src
      resources:
        requests:
          cpu: 100m
      timeout: 4h0m0s
    workflow: ipi-aws
- as: e2e-aws-ocp-${openshift//./}-continuous
  cron: 0 */12 * * 1-5
  steps:
    cluster_profile: aws
    test:
    - as: test
      cli: latest
      commands: make test-e2e
      dependencies:
$image_deps
      from: src
      resources:
        requests:
          cpu: 100m
      timeout: 4h0m0s
    workflow: ipi-aws
EOF
fi
cat <<EOF
resources:
  '*':
    limits:
      memory: 6Gi
    requests:
      cpu: 4
      memory: 6Gi
  'bin':
    limits:
      memory: 6Gi
    requests:
      cpu: 4
      memory: 6Gi

images:
EOF

for img in $core_images; do
  image_base=$(basename $img)
  to_image=$(echo ${image_base//[_.]/-})
  to_image=$(echo ${to_image//v0/upgrade-v0})
  to_image=$(echo ${to_image//migrate/storage-version-migration})
  cat <<EOF
- dockerfile_path: openshift/ci-operator/knative-images/$image_base/Dockerfile
  from: base
  inputs:
    bin:
      paths:
      - destination_dir: .
        source_path: /go/bin/$image_base
  to: knative-eventing-$to_image
EOF
done

for img in $test_images; do
  image_base=$(basename $img)
  to_image=$(echo ${image_base//_/-})
  cat <<EOF
- dockerfile_path: openshift/ci-operator/knative-test-images/$image_base/Dockerfile
  from: base
  inputs:
    test-bin:
      paths:
      - destination_dir: .
        source_path: /go/bin/$image_base
  to: knative-eventing-test-$to_image
EOF
done
