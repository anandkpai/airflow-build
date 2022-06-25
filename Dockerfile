# syntax=docker/dockerfile:1.4

ARG AIRFLOW_HOME=/opt/airflow
ARG AIRFLOW_UID="50000"
ARG AIRFLOW_USER_HOME_DIR=/home/airflow

# latest released version here
ARG AIRFLOW_VERSION="2.3.2"

ARG AIRFLOW_PIP_VERSION=22.1.2

# By default latest released version of airflow is installed (when empty) but this value can be overridden
# and we can install version according to specification (For example ==2.0.2 or <3.0.0).
ARG AIRFLOW_VERSION_SPECIFICATION=""

FROM scratch as scripts


# The content below is automatically copied from scripts/docker/common.sh
COPY <<"EOF" /common.sh
set -euo pipefail

function common::get_colors() {
    COLOR_BLUE=$'\e[34m'
    COLOR_GREEN=$'\e[32m'
    COLOR_RED=$'\e[31m'
    COLOR_RESET=$'\e[0m'
    COLOR_YELLOW=$'\e[33m'
    export COLOR_BLUE
    export COLOR_GREEN
    export COLOR_RED
    export COLOR_RESET
    export COLOR_YELLOW
}


function common::get_airflow_version_specification() {
    if [[ -z ${AIRFLOW_VERSION_SPECIFICATION=}
        && -n ${AIRFLOW_VERSION}
        && ${AIRFLOW_INSTALLATION_METHOD} != "." ]]; then
        AIRFLOW_VERSION_SPECIFICATION="==${AIRFLOW_VERSION}"
    fi
}

function common::override_pip_version_if_needed() {
    if [[ -n ${AIRFLOW_VERSION} ]]; then
        if [[ ${AIRFLOW_VERSION} =~ ^2\.0.* || ${AIRFLOW_VERSION} =~ ^1\.* ]]; then
            export AIRFLOW_PIP_VERSION="22.1.2"
        fi
    fi
}

function common::get_constraints_location() {
    # auto-detect Airflow-constraint reference and location
    if [[ -z "${AIRFLOW_CONSTRAINTS_REFERENCE=}" ]]; then
        if  [[ ${AIRFLOW_VERSION} =~ v?2.* && ! ${AIRFLOW_VERSION} =~ .*dev.* ]]; then
            AIRFLOW_CONSTRAINTS_REFERENCE=constraints-${AIRFLOW_VERSION}
        else
            AIRFLOW_CONSTRAINTS_REFERENCE=${DEFAULT_CONSTRAINTS_BRANCH}
        fi
    fi

    if [[ -z ${AIRFLOW_CONSTRAINTS_LOCATION=} ]]; then
        local constraints_base="https://raw.githubusercontent.com/${CONSTRAINTS_GITHUB_REPOSITORY}/${AIRFLOW_CONSTRAINTS_REFERENCE}"
        local python_version
        python_version="$(python --version 2>/dev/stdout | cut -d " " -f 2 | cut -d "." -f 1-2)"
        AIRFLOW_CONSTRAINTS_LOCATION="${constraints_base}/${AIRFLOW_CONSTRAINTS_MODE}-${python_version}.txt"
    fi
}

function common::show_pip_version_and_location() {
   echo "PATH=${PATH}"
   echo "pip on path: $(which pip)"
   echo "Using pip: $(pip --version)"
}
EOF

# The content below is automatically copied from scripts/docker/prepare_node_modules.sh
COPY <<"EOF" /prepare_node_modules.sh
set -euo pipefail

COLOR_BLUE=$'\e[34m'
readonly COLOR_BLUE
COLOR_RESET=$'\e[0m'
readonly COLOR_RESET

function prepare_node_modules() {
    echo
    echo "${COLOR_BLUE}Preparing node modules${COLOR_RESET}"
    echo
    local www_dir
    if [[ ${AIRFLOW_INSTALLATION_METHOD=} == "." ]]; then
        # In case we are building from sources in production image, we should build the assets
        www_dir="${AIRFLOW_SOURCES_TO=${AIRFLOW_SOURCES}}/airflow/www"
    else
        www_dir="$(python -m site --user-site)/airflow/www"
    fi
    pushd ${www_dir} || exit 1
    set +e
    yarn install --frozen-lockfile --no-cache 2>/tmp/out-yarn-install.txt
    local res=$?
    if [[ ${res} != 0 ]]; then
        >&2 echo
        >&2 echo "Error when running yarn install:"
        >&2 echo
        >&2 cat /tmp/out-yarn-install.txt && rm -f /tmp/out-yarn-install.txt
        exit 1
    fi
    rm -f /tmp/out-yarn-install.txt
    popd || exit 1
}

prepare_node_modules
EOF

# The content below is automatically copied from scripts/docker/entrypoint_prod.sh
COPY <<"EOF" /entrypoint_prod.sh
#!/usr/bin/env bash
AIRFLOW_COMMAND="${1:-}"

set -euo pipefail

LD_PRELOAD="/usr/lib/$(uname -m)-linux-gnu/libstdc++.so.6"
export LD_PRELOAD

function run_check_with_retries {
    local cmd
    cmd="${1}"
    local countdown
    countdown="${CONNECTION_CHECK_MAX_COUNT}"

    while true
    do
        set +e
        local last_check_result
        local res
        last_check_result=$(eval "${cmd} 2>&1")
        res=$?
        set -e
        if [[ ${res} == 0 ]]; then
            echo
            break
        else
            echo -n "."
            countdown=$((countdown-1))
        fi
        if [[ ${countdown} == 0 ]]; then
            echo
            echo "ERROR! Maximum number of retries (${CONNECTION_CHECK_MAX_COUNT}) reached."
            echo
            echo "Last check result:"
            echo "$ ${cmd}"
            echo "${last_check_result}"
            echo
            exit 1
        else
            sleep "${CONNECTION_CHECK_SLEEP_TIME}"
        fi
    done
}

function run_nc() {
    # Checks if it is possible to connect to the host using netcat.
    #
    # We want to avoid misleading messages and perform only forward lookup of the service IP address.
    # Netcat when run without -n performs both forward and reverse lookup and fails if the reverse
    # lookup name does not match the original name even if the host is reachable via IP. This happens
    # randomly with docker-compose in GitHub Actions.
    # Since we are not using reverse lookup elsewhere, we can perform forward lookup in python
    # And use the IP in NC and add '-n' switch to disable any DNS use.
    # Even if this message might be harmless, it might hide the real reason for the problem
    # Which is the long time needed to start some services, seeing this message might be totally misleading
    # when you try to analyse the problem, that's why it's best to avoid it,
    local host="${1}"
    local port="${2}"
    local ip
    ip=$(python -c "import socket; print(socket.gethostbyname('${host}'))")
    nc -zvvn "${ip}" "${port}"
}


function wait_for_connection {
    # Waits for Connection to the backend specified via URL passed as first parameter
    # Detects backend type depending on the URL schema and assigns
    # default port numbers if not specified in the URL.
    # Then it loops until connection to the host/port specified can be established
    # It tries `CONNECTION_CHECK_MAX_COUNT` times and sleeps `CONNECTION_CHECK_SLEEP_TIME` between checks
    local connection_url
    connection_url="${1}"
    local detected_backend
    detected_backend=$(python -c "from urllib.parse import urlsplit; import sys; print(urlsplit(sys.argv[1]).scheme)" "${connection_url}")
    local detected_host
    detected_host=$(python -c "from urllib.parse import urlsplit; import sys; print(urlsplit(sys.argv[1]).hostname or '')" "${connection_url}")
    local detected_port
    detected_port=$(python -c "from urllib.parse import urlsplit; import sys; print(urlsplit(sys.argv[1]).port or '')" "${connection_url}")

    echo BACKEND="${BACKEND:=${detected_backend}}"
    readonly BACKEND

    if [[ -z "${detected_port=}" ]]; then
        if [[ ${BACKEND} == "postgres"* ]]; then
            detected_port=5432
        elif [[ ${BACKEND} == "mysql"* ]]; then
            detected_port=3306
        elif [[ ${BACKEND} == "mssql"* ]]; then
            detected_port=1433
        elif [[ ${BACKEND} == "redis"* ]]; then
            detected_port=6379
        elif [[ ${BACKEND} == "amqp"* ]]; then
            detected_port=5672
        fi
    fi

    detected_host=${detected_host:="localhost"}

    # Allow the DB parameters to be overridden by environment variable
    echo DB_HOST="${DB_HOST:=${detected_host}}"
    readonly DB_HOST

    echo DB_PORT="${DB_PORT:=${detected_port}}"
    readonly DB_PORT
    if [[ -n "${DB_HOST=}" ]] && [[ -n "${DB_PORT=}" ]]; then
        run_check_with_retries "run_nc ${DB_HOST@Q} ${DB_PORT@Q}"
    else
        >&2 echo "The connection details to the broker could not be determined. Connectivity checks were skipped."
    fi
}

function create_www_user() {
    local local_password=""
    # Warning: command environment variables (*_CMD) have priority over usual configuration variables
    # for configuration parameters that require sensitive information. This is the case for the SQL database
    # and the broker backend in this entrypoint script.
    if [[ -n "${_AIRFLOW_WWW_USER_PASSWORD_CMD=}" ]]; then
        local_password=$(eval "${_AIRFLOW_WWW_USER_PASSWORD_CMD}")
        unset _AIRFLOW_WWW_USER_PASSWORD_CMD
    elif [[ -n "${_AIRFLOW_WWW_USER_PASSWORD=}" ]]; then
        local_password="${_AIRFLOW_WWW_USER_PASSWORD}"
        unset _AIRFLOW_WWW_USER_PASSWORD
    fi
    if [[ -z ${local_password} ]]; then
        echo
        echo "ERROR! Airflow Admin password not set via _AIRFLOW_WWW_USER_PASSWORD or _AIRFLOW_WWW_USER_PASSWORD_CMD variables!"
        echo
        exit 1
    fi

    airflow users create \
       --username "${_AIRFLOW_WWW_USER_USERNAME="admin"}" \
       --firstname "${_AIRFLOW_WWW_USER_FIRSTNAME="Airflow"}" \
       --lastname "${_AIRFLOW_WWW_USER_LASTNAME="Admin"}" \
       --email "${_AIRFLOW_WWW_USER_EMAIL="airflowadmin@example.com"}" \
       --role "${_AIRFLOW_WWW_USER_ROLE="Admin"}" \
       --password "${local_password}" || true
}

function create_system_user_if_missing() {
    # This is needed in case of OpenShift-compatible container execution. In case of OpenShift random
    # User id is used when starting the image, however group 0 is kept as the user group. Our production
    # Image is OpenShift compatible, so all permissions on all folders are set so that 0 group can exercise
    # the same privileges as the default "airflow" user, this code checks if the user is already
    # present in /etc/passwd and will create the system user dynamically, including setting its
    # HOME directory to the /home/airflow so that (for example) the ${HOME}/.local folder where airflow is
    # Installed can be automatically added to PYTHONPATH
    if ! whoami &> /dev/null; then
      if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${AIRFLOW_USER_HOME_DIR}:/sbin/nologin" \
            >> /etc/passwd
      fi
      export HOME="${AIRFLOW_USER_HOME_DIR}"
    fi
}

function set_pythonpath_for_root_user() {
    # Airflow is installed as a local user application which means that if the container is running as root
    # the application is not available. because Python then only load system-wide applications.
    # Now also adds applications installed as local user "airflow".
    if [[ $UID == "0" ]]; then
        local python_major_minor
        python_major_minor="$(python --version | cut -d " " -f 2 | cut -d "." -f 1-2)"
        export PYTHONPATH="${AIRFLOW_USER_HOME_DIR}/.local/lib/python${python_major_minor}/site-packages:${PYTHONPATH:-}"
        >&2 echo "The container is run as root user. For security, consider using a regular user account."
    fi
}

function wait_for_airflow_db() {
    # Wait for the command to run successfully to validate the database connection.
    run_check_with_retries "airflow db check"
}

function upgrade_db() {
    # Runs airflow db upgrade
    airflow db upgrade || true
}

function wait_for_celery_broker() {
    # Verifies connection to Celery Broker
    local executor
    executor="$(airflow config get-value core executor)"
    if [[ "${executor}" == "CeleryExecutor" ]]; then
        local connection_url
        connection_url="$(airflow config get-value celery broker_url)"
        wait_for_connection "${connection_url}"
    fi
}

function exec_to_bash_or_python_command_if_specified() {
    # If one of the commands: 'bash', 'python' is used, either run appropriate
    # command with exec
    if [[ ${AIRFLOW_COMMAND} == "bash" ]]; then
       shift
       exec "/bin/bash" "${@}"
    elif [[ ${AIRFLOW_COMMAND} == "python" ]]; then
       shift
       exec "python" "${@}"
    fi
}

function check_uid_gid() {
    if [[ $(id -g) == "0" ]]; then
        return
    fi
    if [[ $(id -u) == "50000" ]]; then
        >&2 echo
        >&2 echo "WARNING! You should run the image with GID (Group ID) set to 0"
        >&2 echo "         even if you use 'airflow' user (UID=50000)"
        >&2 echo
        >&2 echo " You started the image with UID=$(id -u) and GID=$(id -g)"
        >&2 echo
        >&2 echo " This is to make sure you can run the image with an arbitrary UID in the future."
        >&2 echo
        >&2 echo " See more about it in the Airflow's docker image documentation"
        >&2 echo "     http://airflow.apache.org/docs/docker-stack/entrypoint"
        >&2 echo
        # We still allow the image to run with `airflow` user.
        return
    else
        >&2 echo
        >&2 echo "ERROR! You should run the image with GID=0"
        >&2 echo
        >&2 echo " You started the image with UID=$(id -u) and GID=$(id -g)"
        >&2 echo
        >&2 echo "The image should always be run with GID (Group ID) set to 0 regardless of the UID used."
        >&2 echo " This is to make sure you can run the image with an arbitrary UID."
        >&2 echo
        >&2 echo " See more about it in the Airflow's docker image documentation"
        >&2 echo "     http://airflow.apache.org/docs/docker-stack/entrypoint"
        # This will not work so we fail hard
        exit 1
    fi
}

unset PIP_USER

check_uid_gid

umask 0002

CONNECTION_CHECK_MAX_COUNT=${CONNECTION_CHECK_MAX_COUNT:=20}
readonly CONNECTION_CHECK_MAX_COUNT

CONNECTION_CHECK_SLEEP_TIME=${CONNECTION_CHECK_SLEEP_TIME:=3}
readonly CONNECTION_CHECK_SLEEP_TIME

create_system_user_if_missing
set_pythonpath_for_root_user
if [[ "${CONNECTION_CHECK_MAX_COUNT}" -gt "0" ]]; then
    wait_for_airflow_db
fi

if [[ -n "${_AIRFLOW_DB_UPGRADE=}" ]] ; then
    upgrade_db
fi

if [[ -n "${_AIRFLOW_WWW_USER_CREATE=}" ]] ; then
    create_www_user
fi

if [[ -n "${_PIP_ADDITIONAL_REQUIREMENTS=}" ]] ; then
    >&2 echo
    >&2 echo "!!!!!  Installing additional requirements: '${_PIP_ADDITIONAL_REQUIREMENTS}' !!!!!!!!!!!!"
    >&2 echo
    >&2 echo "WARNING: This is a development/test feature only. NEVER use it in production!"
    >&2 echo "         Instead, build a custom image as described in"
    >&2 echo
    >&2 echo "         https://airflow.apache.org/docs/docker-stack/build.html"
    >&2 echo
    >&2 echo "         Adding requirements at container startup is fragile and is done every time"
    >&2 echo "         the container starts, so it is onlny useful for testing and trying out"
    >&2 echo "         of adding dependencies."
    >&2 echo
    pip install --root-user-action ignore --no-cache-dir ${_PIP_ADDITIONAL_REQUIREMENTS}
fi


exec_to_bash_or_python_command_if_specified "${@}"

if [[ ${AIRFLOW_COMMAND} == "airflow" ]]; then
   AIRFLOW_COMMAND="${2:-}"
   shift
fi

if [[ ${AIRFLOW_COMMAND} =~ ^(scheduler|celery)$ ]] \
    && [[ "${CONNECTION_CHECK_MAX_COUNT}" -gt "0" ]]; then
    wait_for_celery_broker
fi

exec "airflow" "${@}"
EOF

# The content below is automatically copied from scripts/docker/clean-logs.sh
COPY <<"EOF" /clean-logs.sh
#!/usr/bin/env bash


set -euo pipefail

readonly DIRECTORY="${AIRFLOW_HOME:-/usr/local/airflow}"
readonly RETENTION="${AIRFLOW__LOG_RETENTION_DAYS:-15}"

trap "exit" INT TERM

readonly EVERY=$((15*60))

echo "Cleaning logs every $EVERY seconds"

while true; do
  echo "Trimming airflow logs to ${RETENTION} days."
  find "${DIRECTORY}"/logs \
    -type d -name 'lost+found' -prune -o \
    -type f -mtime +"${RETENTION}" -name '*.log' -print0 | \
    xargs -0 rm -f

  seconds=$(( $(date -u +%s) % EVERY))
  (( seconds < 1 )) || sleep $((EVERY - seconds))
done
EOF

# The content below is automatically copied from scripts/docker/airflow-scheduler-autorestart.sh
COPY <<"EOF" /airflow-scheduler-autorestart.sh
#!/usr/bin/env bash

while echo "Running"; do
    airflow scheduler -n 5
    return_code=$?
    if (( return_code != 0 )); then
        echo "Scheduler crashed with exit code $return_code. Respawning.." >&2
        date >> /tmp/airflow_scheduler_errors.txt
    fi

    sleep 1
done
EOF

##############################################################################################
# This is the build image where we build all dependencies
##############################################################################################

FROM apache/airflow:2.3.2-python3.9 as airflow-build-image

ARG AIRFLOW_VERSION
ARG AIRFLOW_HOME
ARG AIRFLOW_USER_HOME_DIR
ARG AIRFLOW_UID
COPY ${DOCKER_CONTEXT_FILES} /docker-context-files

# RUN adduser --gecos "First Last,RoomNumber,WorkPhone,HomePhone" --disabled-password \
#        --quiet "airflow" --uid "${AIRFLOW_UID}" --gid "0" --home "${AIRFLOW_USER_HOME_DIR}" && \
#     mkdir -p ${AIRFLOW_HOME} && chown -R "airflow:0" "${AIRFLOW_USER_HOME_DIR}" ${AIRFLOW_HOME}

USER airflow

WORKDIR ${AIRFLOW_HOME}

##############################################################################################
# This is the  Airflow image we use 
##############################################################################################
FROM airflow-build-image as main

# Nolog bash flag is currently ignored - but you can replace it with other flags (for example
# xtrace - to show commands executed)
SHELL ["/bin/bash", "-o", "pipefail", "-o", "errexit", "-o", "nounset", "-o", "nolog", "-c"]

ARG AIRFLOW_UID

LABEL org.apache.airflow.distro="debian" \
  org.apache.airflow.module="airflow" \
  org.apache.airflow.component="airflow" \
  org.apache.airflow.image="airflow" \
  org.apache.airflow.uid="${AIRFLOW_UID}"


ARG AIRFLOW_USER_HOME_DIR
ARG AIRFLOW_HOME

# By default PIP installs everything to ~/.local
ENV PATH="${AIRFLOW_USER_HOME_DIR}/.local/bin:${PATH}" \
    AIRFLOW_UID=${AIRFLOW_UID} \
    AIRFLOW_USER_HOME_DIR=${AIRFLOW_USER_HOME_DIR} \
    AIRFLOW_HOME=${AIRFLOW_HOME}

# COPY --from=scripts install_mysql.sh install_mssql.sh install_postgres.sh /scripts/docker/
# We run scripts with bash here to make sure we can execute the scripts. Changing to +x might have an
# unexpected result - the cache for Dockerfiles might get invalidated in case the host system
# had different umask set and group x bit was not set. In Azure the bit might be not set at all.
# That also protects against AUFS Docker backend problem where changing the executable bit required sync
RUN mkdir -pv "${AIRFLOW_HOME}" 
RUN mkdir -pv "${AIRFLOW_HOME}/dags" 
RUN mkdir -pv "${AIRFLOW_HOME}/logs" 
RUN chown -R airflow:0 "${AIRFLOW_USER_HOME_DIR}" "${AIRFLOW_HOME}" 
RUN chmod -R g+rw "${AIRFLOW_USER_HOME_DIR}" "${AIRFLOW_HOME}" 
RUN find "${AIRFLOW_HOME}" -executable -print0 | xargs --null chmod g+x 
RUN find "${AIRFLOW_USER_HOME_DIR}" -executable -print0 | xargs --null chmod g+x

COPY --from=airflow-build-image --chown=airflow:0 \
     "${AIRFLOW_USER_HOME_DIR}/.local" "${AIRFLOW_USER_HOME_DIR}/.local"
COPY --from=scripts entrypoint_prod.sh /entrypoint
COPY --from=scripts clean-logs.sh /clean-logs
COPY --from=scripts airflow-scheduler-autorestart.sh /airflow-scheduler-autorestart

# Make /etc/passwd root-group-writeable so that user can be dynamically added by OpenShift
# See https://github.com/apache/airflow/issues/9248
# Set default groups for airflow and root user
USER root

RUN chmod a+rx /entrypoint /clean-logs \
    && chmod g=u /etc/passwd \
    && chmod g+w "${AIRFLOW_USER_HOME_DIR}/.local" \
    && usermod -g 0 airflow -G 0

# make sure that the venv is activated for all users
# including plain sudo, sudo with --interactive flag
RUN sed --in-place=.bak "s/secure_path=\"/secure_path=\"\/.venv\/bin:/" /etc/sudoers

ARG AIRFLOW_VERSION

# See https://airflow.apache.org/docs/docker-stack/entrypoint.html#signal-propagation
# to learn more about the way how signals are handled by the image
# Also set airflow as nice PROMPT message.
ENV DUMB_INIT_SETSID="1" \
    PS1="(airflow)" \
    AIRFLOW_VERSION=${AIRFLOW_VERSION} \
    AIRFLOW__CORE__LOAD_EXAMPLES="false" \
    PIP_USER="true" \
    PATH="/root/bin:${PATH}"

# Add protection against running pip as root user
# RUN mkdir -pv /root/bin
# COPY --from=scripts pip /root/bin/pip
# RUN chmod u+x /root/bin/pip

WORKDIR ${AIRFLOW_HOME}

EXPOSE 8080

RUN mkdir /nfs_genesis  && chown airflow:0 /nfs_genesis

USER ${AIRFLOW_UID}

# Those should be set and used as late as possible as any change in commit/build otherwise invalidates the
# layers right after
ARG BUILD_ID
ARG COMMIT_SHA
ARG AIRFLOW_IMAGE_REPOSITORY
ARG AIRFLOW_IMAGE_DATE_CREATED

ENV BUILD_ID=${BUILD_ID} COMMIT_SHA=${COMMIT_SHA}

LABEL org.apache.airflow.distro="debian" \
  org.apache.airflow.module="airflow" \
  org.apache.airflow.component="airflow" \
  org.apache.airflow.image="airflow" \
  org.apache.airflow.version="${AIRFLOW_VERSION}" \
  org.apache.airflow.uid="${AIRFLOW_UID}" \
  org.apache.airflow.main-image.build-id="${BUILD_ID}" \
  org.apache.airflow.main-image.commit-sha="${COMMIT_SHA}" \
  org.opencontainers.image.source="${AIRFLOW_IMAGE_REPOSITORY}" \
  org.opencontainers.image.created=${AIRFLOW_IMAGE_DATE_CREATED} \
  org.opencontainers.image.authors="dev@airflow.apache.org" \
  org.opencontainers.image.url="https://airflow.apache.org" \
  org.opencontainers.image.documentation="https://airflow.apache.org/docs/docker-stack/index.html" \
  org.opencontainers.image.version="${AIRFLOW_VERSION}" \
  org.opencontainers.image.revision="${COMMIT_SHA}" \
  org.opencontainers.image.vendor="Apache Software Foundation" \
  org.opencontainers.image.licenses="Apache-2.0" \
  org.opencontainers.image.ref.name="airflow" \
  org.opencontainers.image.title="Production Airflow Image" \
  org.opencontainers.image.description="Reference, production-ready Apache Airflow image"
ENTRYPOINT ["/usr/bin/dumb-init", "--", "/entrypoint"]
CMD []
