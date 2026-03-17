ARG ALPINE_VERSION=3.23.3
FROM alpine:${ALPINE_VERSION} AS builder

ARG FIREFLY_VERSION
WORKDIR /app

RUN apk add --no-cache unzip

ADD https://github.com/firefly-iii/firefly-iii/releases/download/${FIREFLY_VERSION}/FireflyIII-${FIREFLY_VERSION}.zip ./
RUN unzip FireflyIII-${FIREFLY_VERSION}.zip && \
    rm FireflyIII-${FIREFLY_VERSION}.zip

RUN <<EOF
    set -e
    ROOT="/app"

    SIZE_BEFORE=$(du -sm . | cut -f1)
    
    cd $ROOT/vendor
    PKGS="
    phpstan/phpstan/phpstan.phar:
    fakerphp/faker/src/Faker/Provider:
    rector/rector/vendor:
    rector/rector/rules:
    phpunit:phpunit/phpunit/src/Framework/Assert/Functions.php
    :phpunit/phpunit/src/Runner/Version.php
    mockery:mockery/mockery/library/helpers.php
    :mockery/mockery/library/Mockery.php
    "

    for ENTRY in $PKGS; do
        TOP_DIR=${ENTRY%%:*}
        STUB_FILE=${ENTRY#*:}
        
        [ -n "$TOP_DIR" ] && rm -rf "$TOP_DIR"
        [ -n "$STUB_FILE" ] && ( mkdir -p "$(dirname "$STUB_FILE")" && echo "<?php" > "$STUB_FILE" )
    done

    rm -rf larastan hamcrest phar-io theseer

    cd $ROOT/resources/lang
    find . -maxdepth 1 -type d ! -name "." ! -name "en_US" ! -name "zh_CN" ! -name "ja_JP" -exec rm -rf {} +
    rm -rf $ROOT/resources/assets

    cd $ROOT
    find . -type d \( -name "tests" -o -name "test" -o -name "docs" -o -name ".github" -o -name "examples" \) -exec rm -rf {} + && \
    find . -type f \( -name "*.md" -o -name "*.txt" -o -name "LICENSE*" -o -name ".gitignore" -o -name "phpunit.xml*" -o -name ".editorconfig" \) -delete

    cd $ROOT
    SIZE_AFTER=$(du -sm . | cut -f1)
    echo "------------------------------------------------"
    echo "  Cleanup Result: $SIZE_BEFORE MB -> $SIZE_AFTER MB"
    echo "  Saved: $((SIZE_BEFORE - SIZE_AFTER)) MB"
    echo "------------------------------------------------"
EOF

FROM alpine:${ALPINE_VERSION}

ARG FIREFLY_VERSION
LABEL Maintainer="lzc256 <i@lzc256.com>"
WORKDIR /var/www/html

RUN apk add --no-cache \
    nginx \
    php85 php85-fpm php85-bcmath php85-intl php85-curl php85-zip \
    php85-sodium php85-gd php85-xml php85-mbstring php85-pdo_sqlite \
    php85-session php85-tokenizer php85-dom php85-simplexml php85-xmlwriter php85-openssl php85-fileinfo \
    && ln -s /usr/bin/php85 /usr/bin/php \
    && rm -rf /var/cache/apk/* /tmp/*

COPY --from=builder --chown=nobody:nobody /app /var/www/html

COPY config/nginx.conf /etc/nginx/nginx.conf
COPY config/conf.d /etc/nginx/conf.d/
ENV PHP_INI_DIR=/etc/php85
COPY config/fpm-pool.conf ${PHP_INI_DIR}/php-fpm.d/www.conf
COPY config/php.ini ${PHP_INI_DIR}/conf.d/custom.ini

RUN chown -R nobody:nobody /var/www/html /run /var/lib/nginx /var/log/nginx

USER nobody

HEALTHCHECK --timeout=10s CMD curl --silent --fail http://127.0.0.1:8080/fpm-ping || exit 1

CMD ["sh", "-c", "trap 'kill -TERM $P1 $P2' SIGTERM; php-fpm85 -F & P1=$!; nginx -g 'daemon off;' & P2=$!; wait $P1 $P2"]
