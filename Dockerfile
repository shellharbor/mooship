ARG PHP_IMAGE=php:8.3-fpm-bookworm@sha256:f768bd9142444f6126a690697b028c23f30878c3b628a7c355dfce75e29cc045
ARG NGINX_IMAGE=nginx:1.31.0-alpine@sha256:2f07d83bf561b506400dc183b1b2003803e39efbd22451f848adaba14d28c7c7
ARG MOODLE_VERSION=4.5.15
ARG MOODLE_COMMIT=0a694ba9b8b4183bf7a45094cfa7211030db3192
ARG MOODLE_SHA256=19d8ab675769cd631b733c63914d1e318acad575763c75ef7e7e238f4180ed70

FROM ${PHP_IMAGE} AS extensions
ARG REDIS_VERSION=6.3.0
RUN apt-get update && apt-get install -y --no-install-recommends \
        libicu-dev libpq-dev libzip-dev libpng-dev libjpeg62-turbo-dev \
        libfreetype6-dev libonig-dev libxml2-dev libwebp-dev \
    && docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp \
    && docker-php-ext-install -j2 intl mysqli pgsql pdo_mysql pdo_pgsql zip gd soap exif opcache bcmath sockets mbstring \
    && pecl install "redis-${REDIS_VERSION}" </dev/null \
    && docker-php-ext-enable redis \
    && rm -rf /var/lib/apt/lists/*

FROM ${PHP_IMAGE} AS source
ARG MOODLE_VERSION
ARG MOODLE_COMMIT
ARG MOODLE_SHA256
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && mkdir -p /opt/moodle /opt/mooship \
    && test -n "${MOODLE_SHA256}" \
    && curl --fail --location --retry 3 --output /tmp/moodle.tar.gz \
        "https://codeload.github.com/moodle/moodle/tar.gz/${MOODLE_COMMIT}" \
    && printf '%s  /tmp/moodle.tar.gz\n' "${MOODLE_SHA256}" | sha256sum --check - \
    && tar -xzf /tmp/moodle.tar.gz --strip-components=1 --no-same-owner -C /opt/moodle \
    && rm /tmp/moodle.tar.gz \
    && php -r 'define("MOODLE_INTERNAL", true); define("MATURITY_STABLE", 200); require "/opt/moodle/version.php"; \
        if (explode(" ", $release)[0] !== getenv("MOODLE_VERSION")) { exit(1); } \
        file_put_contents("/opt/mooship/version.json", json_encode(["release" => $release, "version" => $version]));' \
    && chmod -R a-w /opt/moodle

FROM ${NGINX_IMAGE} AS web
ARG MOODLE_VERSION
ARG MOOSHIP_VERSION=dev
ARG VCS_REF=unknown
LABEL org.opencontainers.image.title="Mooship Moodle web server" \
      org.opencontainers.image.source="https://github.com/shellharbor/mooship" \
      org.opencontainers.image.version="${MOOSHIP_VERSION}-moodle${MOODLE_VERSION}-nginx" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later AND MIT"
RUN addgroup -g 1000 mooship && adduser -D -H -u 1000 -G mooship mooship \
    && mkdir -p /var/moodledata /opt/mooship \
    && chown 1000:1000 /var/moodledata
COPY --from=source /opt/moodle /opt/moodle
COPY docker/nginx.conf.template docker/health.txt /opt/mooship/
COPY --chmod=755 docker/web-entrypoint.sh /usr/local/bin/mooship-web
COPY LICENSE /opt/mooship/LICENSE
USER 1000:1000
EXPOSE 8080
STOPSIGNAL SIGQUIT
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q -O - http://127.0.0.1:8080/healthz | grep -qx ok
ENTRYPOINT ["/usr/local/bin/mooship-web"]

FROM ${PHP_IMAGE} AS app
ARG MOODLE_VERSION
ARG MOOSHIP_VERSION=dev
ARG VCS_REF=unknown
LABEL org.opencontainers.image.title="Mooship Moodle runtime" \
      org.opencontainers.image.source="https://github.com/shellharbor/mooship" \
      org.opencontainers.image.version="${MOOSHIP_VERSION}-moodle${MOODLE_VERSION}-php8.3" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.licenses="GPL-3.0-or-later AND MIT"
RUN apt-get update && apt-get install -y --no-install-recommends \
        libicu72 libpq5 libzip4 libpng16-16 libjpeg62-turbo libfreetype6 \
        libonig5 libxml2 libwebp7 libfcgi-bin tini \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 1000 mooship \
    && useradd --uid 1000 --gid 1000 --home-dir /var/moodledata --no-create-home --shell /usr/sbin/nologin mooship \
    && mkdir -p /var/moodledata /opt/mooship \
    && chown 1000:1000 /var/moodledata \
    && chmod 2770 /var/moodledata \
    && cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini \
    && rm /usr/local/etc/php-fpm.d/*.conf
COPY --from=extensions /usr/local/lib/php/extensions/ /usr/local/lib/php/extensions/
COPY --from=extensions /usr/local/etc/php/conf.d/ /usr/local/etc/php/conf.d/
COPY --from=source /opt/moodle /opt/moodle
COPY --from=source /opt/mooship/version.json /opt/mooship/version.json
COPY docker/config.php /opt/moodle/config.php
COPY docker/environment.php docker/validate.php docker/readiness.php docker/install.php /opt/mooship/
COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/mooship
COPY --chmod=755 docker/healthcheck.sh /usr/local/bin/mooship-healthcheck
COPY --chmod=755 docker/cron.sh /opt/mooship/cron.sh
COPY docker/php-fpm.conf /usr/local/etc/php-fpm.d/mooship.conf
COPY moodle/.config/php/mooship.ini /usr/local/etc/php/conf.d/zz-mooship.ini
COPY LICENSE /opt/mooship/LICENSE
ENV PHP_FPM_MAX_CHILDREN=4
USER 1000:1000
WORKDIR /opt/moodle
EXPOSE 9000
STOPSIGNAL SIGQUIT
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 CMD ["/usr/local/bin/mooship-healthcheck"]
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/mooship"]
CMD ["fpm"]
