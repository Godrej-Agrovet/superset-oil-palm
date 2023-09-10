#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Stage 1: Node stage for handling static asset construction
ARG BUILDPLATFORM=amd64
FROM --platform=${BUILDPLATFORM} node:16-slim AS superset-node

# Set environment variables
ARG NPM_BUILD_CMD="build"
ENV BUILD_CMD=${NPM_BUILD_CMD} \
    PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true

# Create a working directory
WORKDIR /app/superset-frontend

# Run the frontend memory nag script
RUN --mount=type=bind,target=/frontend-mem-nag.sh,src=./docker/frontend-mem-nag.sh \
    /frontend-mem-nag.sh

# Copy package.json and install dependencies
COPY superset-frontend/package*.json ./
RUN npm ci

# Copy the frontend source code and build assets
COPY ./superset-frontend ./
RUN npm run ${BUILD_CMD}

# Stage 2: Final lean image
FROM python:3.9-slim-bookworm AS lean

# Set environment variables
WORKDIR /app
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SUPERSET_ENV=production \
    FLASK_APP="superset.app:create_app()" \
    PYTHONPATH="/app/pythonpath" \
    SUPERSET_HOME="/app/superset_home" \
    SUPERSET_PORT=8088

# Create necessary directories and user
RUN mkdir -p ${PYTHONPATH} superset/static superset-frontend apache_superset.egg-info requirements \
    && useradd --user-group -d ${SUPERSET_HOME} -m --no-log-init --shell /bin/bash superset

# Install system dependencies
RUN apt-get update && apt-get install --no-install-recommends -y \
    build-essential \
    curl \
    gnupg2 \
    default-libmysqlclient-dev \
    libsasl2-dev \
    libsasl2-modules-gssapi-mit \
    libpq-dev \
    libecpg-dev \
    libldap2-dev \
    unixodbc-dev \
    unixodbc \
    libpq-dev \
    postgresql-client \
    libhdf5-dev \
    libxml2-dev \
    libxmlsec1-dev \
    binutils \
    libproj-dev \
    gdal-bin \
    python3-gdal \
    gettext \
    libgssapi-krb5-2

# Install MS SQL tools
RUN curl https://packages.microsoft.com/keys/microsoft.asc | apt-key add -
RUN curl https://packages.microsoft.com/config/debian/10/prod.list > /etc/apt/sources.list.d/mssql-release.list
RUN apt-get update && ACCEPT_EULA=Y apt-get install -y msodbcsql17 mssql-tools
RUN echo 'export PATH="$PATH:/opt/mssql-tools/bin"' >> ~/.bashrc \
    && echo 'export PATH="$PATH:/opt/mssql-tools/bin"' >> ~/.bash_profile \
    && /bin/bash -c "source ~/.bashrc" \
    && echo MinProtocol = TLSv1.0 >> /etc/ssl/openssl.cnf \
    && echo CipherString = DEFAULT@SECLEVEL=0 >> /etc/ssl/openssl.cnf

# Copy requirements and install them
COPY --chown=superset:superset ./requirements/*.txt requirements/
COPY --chown=superset:superset setup.py MANIFEST.in README.md ./
COPY --chown=superset:superset superset-frontend/package.json superset-frontend/
RUN pip install --no-cache-dir -r requirements/local.txt

# Copy openssl.cnf
COPY docker/openssl.cnf /etc/ssl/openssl.cnf

# Copy static assets and install Superset
COPY --chown=superset:superset --from=superset-node /app/superset/static/assets superset/static/assets
COPY --chown=superset:superset superset superset
RUN pip install --no-cache-dir -e . \
    && flask fab babel-compile --target superset/translations \
    && chown -R superset:superset superset/translations

# Copy run-server.sh and set user
COPY --chmod=755 ./docker/run-server.sh /usr/bin/
USER superset

# Healthcheck, expose port, and define the default command
HEALTHCHECK CMD curl -f "http://localhost:$SUPERSET_PORT/health"
EXPOSE ${SUPERSET_PORT}
CMD ["/usr/bin/run-server.sh"]


######################################################################
# Dev image...
######################################################################
FROM lean AS dev
ARG GECKODRIVER_VERSION=v0.32.0 \
    FIREFOX_VERSION=106.0.3

USER root

RUN apt-get update -q \
    && apt-get install -yq --no-install-recommends \
        libnss3 \
        libdbus-glib-1-2 \
        libgtk-3-0 \
        libx11-xcb1 \
        libasound2 \
        libxtst6 \
        wget \
    # Install GeckoDriver WebDriver
    && wget https://github.com/mozilla/geckodriver/releases/download/${GECKODRIVER_VERSION}/geckodriver-${GECKODRIVER_VERSION}-linux64.tar.gz -O - | tar xfz - -C /usr/local/bin \
    # Install Firefox
    && wget https://download-installer.cdn.mozilla.net/pub/firefox/releases/${FIREFOX_VERSION}/linux-x86_64/en-US/firefox-${FIREFOX_VERSION}.tar.bz2 -O - | tar xfj - -C /opt \
    && ln -s /opt/firefox/firefox /usr/local/bin/firefox \
    && apt-get autoremove -yqq --purge wget && rm -rf /var/lib/apt/lists/* /var/[log,tmp]/* /tmp/* && apt-get clean

# Cache everything for dev purposes...
RUN pip install --no-cache-dir -r requirements/docker.txt

USER superset


######################################################################
# CI image...
######################################################################
FROM lean AS ci

COPY --chown=superset:superset --chmod=755 ./docker/*.sh /app/docker/

CMD ["/app/docker/docker-ci.sh"]

