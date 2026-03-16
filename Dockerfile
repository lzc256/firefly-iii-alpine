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
    curl nginx \
    php85 php85-fpm php85-bcmath php85-intl php85-curl php85-zip \
    php85-sodium php85-gd php85-xml php85-mbstring php85-pdo_sqlite \
    php85-session php85-tokenizer php85-dom php85-simplexml php85-xmlwriter php85-openssl php85-fileinfo \
    && ln -s /usr/bin/php85 /usr/bin/php \
    && rm -rf /var/cache/apk/*

COPY --from=builder --chown=nobody:nobody /app /var/www/html

RUN <<EOF
    set -e
    cd /var/www/html/vendor

    SIZE_BEFORE=$(du -sm . | cut -f1)

    # 1. 精准删除名单：[要删除的特定子目录]:[需要复活的桩文件]
    # 这样 nunomaduro/collision 会被删，但 nunomaduro/termwind 会被跳过或精准复活
    PKGS="
    phpstan/phpstan:phpstan/phpstan/bootstrap.php
    rector/rector:rector/rector/bootstrap.php
    mockery/mockery:mockery/library/helpers.php
    mockery/mockery:mockery/library/Mockery.php
    fakerphp/faker:fakerphp/faker/src/Faker/Factory.php
    spatie/flare-client-php:spatie/flare-client-php/src/helpers.php
    spatie/laravel-ignition:spatie/laravel-ignition/src/helpers.php
    nunomaduro/collision:nunomaduro/collision/src/Adapters/Phpunit/Autoload.php
    nunomaduro/termwind:nunomaduro/termwind/src/Functions.php
    phpunit/phpunit:phpunit/phpunit/src/Framework/Assert/Functions.php
    "

    # 2. 第一步：执行针对性删除和复活
    for ENTRY in $PKGS; do
        TARGET_DIR=${ENTRY%%:*}
        STUB_FILE=${ENTRY#*:}
        
        # 只删特定的子包目录，不伤及其父目录下的其他兄弟
        rm -rf "$TARGET_DIR"
        
        # 重建桩文件
        mkdir -p "$(dirname "$STUB_FILE")"
        echo "<?php" > "$STUB_FILE"
    done

    # 3. 第二步：暴力清理其他完全无关的包（这些包没有 require 钩子）
    rm -rf larastan hamcrest sebastian phar-io theseer barryvdh thecodingmachine

    # 4. 第三步：全量深度扫除杂质文件（tests, docs, md 等）
    # 放在最后执行，确保它清理掉那些“健康包”里的垃圾，但由于我们已经 touch 了桩文件，它们会留下来
    find . -type d \( -name "tests" -o -name "test" -o -name "docs" -o -name ".github" -o -name "examples" \) -exec rm -rf {} + && find . -type f \( -name "*.md" -o -name "*.txt" -o -name "LICENSE*" -o -name ".gitignore" -o -name "phpunit.xml*" -o -name ".editorconfig" \) -delete

    SIZE_AFTER=$(du -sm . | cut -f1)
    echo "------------------------------------------------"
    echo "  Cleanup Summary: Saved $((SIZE_BEFORE - SIZE_AFTER)) MB"
    echo "  Final Vendor Size: ${SIZE_AFTER} MB"
    echo "------------------------------------------------"

    rm -rf /var/cache/apk/* /tmp/*
EOF

COPY config/nginx.conf /etc/nginx/nginx.conf
COPY config/conf.d /etc/nginx/conf.d/
ENV PHP_INI_DIR=/etc/php85
COPY config/fpm-pool.conf ${PHP_INI_DIR}/php-fpm.d/www.conf
COPY config/php.ini ${PHP_INI_DIR}/conf.d/custom.ini

RUN chown -R nobody:nobody /var/www/html /run /var/lib/nginx /var/log/nginx

USER nobody

HEALTHCHECK --timeout=10s CMD curl --silent --fail http://127.0.0.1:8080/fpm-ping || exit 1

CMD php-fpm85 -F & nginx -g 'daemon off;' & wait -n
