ARG ALPINE_VERSION=3.23.3
FROM alpine:${ALPINE_VERSION} AS builder

ARG FIREFLY_VERSION
WORKDIR /app

RUN apk add --no-cache unzip curl

ADD https://github.com/firefly-iii/firefly-iii/releases/download/${FIREFLY_VERSION}/FireflyIII-${FIREFLY_VERSION}.zip ./
RUN unzip FireflyIII-${FIREFLY_VERSION}.zip && \
    rm FireflyIII-${FIREFLY_VERSION}.zip

FROM alpine:${ALPINE_VERSION}

ARG FIREFLY_VERSION
LABEL Maintainer="lzc256 <i@lzc256.com>"
WORKDIR /var/www/html

RUN apk add --no-cache \
    curl nginx supervisor \
    php85 php85-fpm php85-bcmath php85-intl php85-curl php85-zip \
    php85-sodium php85-gd php85-xml php85-mbstring php85-pdo_sqlite \
    php85-session php85-tokenizer php85-dom php85-simplexml php85-xmlwriter php85-openssl \
    && apk del python3 \
    && ln -s /usr/bin/php85 /usr/bin/php \
    && rm -rf /var/cache/apk/*

COPY --from=builder --chown=nobody:nobody /app /var/www/html

RUN <<EOF
    set -e
    cd vendor

    rm -rf \
        rector/ \
        phpstan/ \
        larastan/ \
        fakerphp/ \
        mockery/ \
        hamcrest/ \
        sebastian/ \
        phar-io/ \
        theseer/ \
        barryvdh/ \
        fruitcake/ \
        phpunit/ \
        nunomaduro/collision \
        spatie/backtrace \
        spatie/flare-client-php \
        spatie/ignition \
        spatie/laravel-ignition

    find . -type d \( -name "tests" -o -name "docs" -o -name ".github" \) -exec rm -rf {} +
    
    find . -type f \( \
        -name "*.md" \
        -o -name "*.txt" \
        -o -name "LICENSE*" \
        -o -name ".gitignore" \
        -o -name "phpunit.xml*" \
        -o -name "composer.json" \
    \) -delete

    cd /var/www/html

    curl -sS https://getcomposer.org/composer-stable.phar -o composer.phar
    php composer.phar dump-autoload --no-dev --optimize --classmap-authoritative
    rm composer.phar

EOF


COPY config/nginx.conf /etc/nginx/nginx.conf
COPY config/conf.d /etc/nginx/conf.d/
ENV PHP_INI_DIR=/etc/php85
COPY config/fpm-pool.conf ${PHP_INI_DIR}/php-fpm.d/www.conf
COPY config/php.ini ${PHP_INI_DIR}/conf.d/custom.ini
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

RUN chown -R nobody:nobody /var/www/html /run /var/lib/nginx /var/log/nginx

USER nobody
EXPOSE 8080

HEALTHCHECK --timeout=10s CMD curl --silent --fail http://127.0.0.1:8080/fpm-ping || exit 1

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
