#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
FROM amazoncorretto:21-alpine AS builder
WORKDIR /build
COPY . /build
RUN ./gradlew publishToMavenLocal


FROM amazoncorretto:21-alpine AS runner

ARG accounting_port=2025

ENV server.max-http-header-size=16384 \
    cassandra.clusterName="Test Cluster" \
    server.port=$accounting_port \
    ACCOUNTING_PORT=$accounting_port

# Run as an unprivileged account rather than root. The task definition mounts
# an ephemeral volume at /tmp, so the JVM still has somewhere to write while
# the rest of the root filesystem stays read-only.
RUN addgroup -S fineract && adduser -S -G fineract -h /opt/fineract fineract

WORKDIR /opt/fineract
COPY --from=builder --chown=fineract:fineract \
    /build/service/build/libs/service-*-boot.jar ./accounting-service-boot.jar

USER fineract

EXPOSE $accounting_port

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
    CMD wget -q -O /dev/null "http://127.0.0.1:${ACCOUNTING_PORT}/accounting/v1" || exit 1

CMD ["java", "-jar", "accounting-service-boot.jar"]
