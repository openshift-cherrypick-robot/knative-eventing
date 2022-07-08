# Do not edit! This file was generated via Makefile
FROM registry.ci.openshift.org/openshift/release:golang-1.17 as builder

COPY . .
RUN make install test-install

FROM openshift/origin-base
USER 65532

COPY ./test/test_images/event-library/kodata /var/run/ko
COPY --from=builder /go/bin/event-library /usr/bin/event-library
ENTRYPOINT ["/usr/bin/event-library"]
