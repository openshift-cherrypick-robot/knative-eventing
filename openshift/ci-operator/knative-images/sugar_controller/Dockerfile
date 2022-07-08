# Do not edit! This file was generated via Makefile
FROM registry.ci.openshift.org/openshift/release:golang-1.17 as builder

COPY . .
RUN make install test-install

FROM openshift/origin-base
USER 65532

COPY ./cmd/sugar_controller/kodata /var/run/ko
COPY --from=builder /go/bin/sugar_controller /usr/bin/sugar_controller
ENTRYPOINT ["/usr/bin/sugar_controller"]
