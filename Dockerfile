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

    # 1. 精准删除与桩文件名单
    # 增加 thecodingmachine 的修复
    PKGS="
    phpstan:phpstan/phpstan/bootstrap.php
    rector:rector/rector/bootstrap.php
    mockery:mockery/library/helpers.php
    mockery:mockery/library/Mockery.php
    fakerphp:fakerphp/faker/src/Faker/Factory.php
    spatie/flare-client-php:spatie/flare-client-php/src/helpers.php
    spatie/laravel-ignition:spatie/laravel-ignition/src/helpers.php
    nunomaduro/collision:nunomaduro/collision/src/Adapters/Phpunit/Autoload.php
    nunomaduro/termwind:nunomaduro/termwind/src/Functions.php
    phpunit/phpunit:phpunit/phpunit/src/Framework/Assert/Functions.php
    thecodingmachine/safe:thecodingmachine/safe/lib/special_cases.php
    "

    # 执行精准删除和复活
    for ENTRY in $PKGS; do
        TARGET_DIR=${ENTRY%%:*}
        STUB_FILE=${ENTRY#*:}
        rm -rf "$TARGET_DIR"
        mkdir -p "$(dirname "$STUB_FILE")"
        echo "<?php" > "$STUB_FILE"
    done

    # 2. 暴力删除其他无钩子的包
    rm -rf larastan hamcrest sebastian phar-io theseer barryvdh

    # 3. 全量深度大扫除 (vendor 内部)
    find . -type d \( -name "tests" -o -name "test" -o -name "docs" -o -name ".github" -o -name "examples" \) -exec rm -rf {} + && \
    find . -type f \( -name "*.md" -o -name "*.txt" -o -name "LICENSE*" -o -name ".gitignore" -o -name "phpunit.xml*" -o -name ".editorconfig" \) -delete

    # 4. 语言包与资源清理 (resources 瘦身)
    echo "Cleaning up languages and assets..."
    cd /var/www/html/resources/lang
    # 只留 zh_CN, en_US, ja_JP
    find . -maxdepth 1 -type d ! -name "." ! -name "en_US" ! -name "zh_CN" ! -name "ja_JP" -exec rm -rf {} +
    
    # 删除原始前端源码 (已经编译到 public 了)
    rm -rf /var/www/html/resources/assets

    # 5. 结果统计
    SIZE_AFTER=$(du -sm /var/www/html/vendor | cut -f1)
    echo "------------------------------------------------"
    echo "  Cleanup Summary: Saved $((SIZE_BEFORE - SIZE_AFTER)) MB"
    echo "  Final Vendor Size: ${SIZE_AFTER} MB"
    echo "  Final Resources Size: $(du -sh /var/www/html/resources | cut -f1)"
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
