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

    # 1. 名单：[顶级根目录]:[复活的桩文件相对路径]
    # 已移除 thecodingmachine，确保不再产生 require 报错
    PKGS="
    phpstan:phpstan/phpstan/bootstrap.php
    rector:rector/rector/bootstrap.php
    mockery:mockery/library/helpers.php
    :mockery/mockery/library/Mockery.php
    fakerphp:fakerphp/faker/src/Faker/Factory.php
    spatie:spatie/flare-client-php/src/helpers.php
    :spatie/laravel-ignition/src/helpers.php
    nunomaduro:nunomaduro/collision/src/Adapters/Phpunit/Autoload.php
    :nunomaduro/termwind/src/Functions.php
    phpunit:phpunit/phpunit/src/Framework/Assert/Functions.php
    "

    # 2. 核心循环：爆破根目录 + 复活必要桩文件
    for ENTRY in $PKGS; do
        TOP_DIR=${ENTRY%%:*}
        STUB_FILE=${ENTRY#*:}
        
        if [ -n "$TOP_DIR" ]; then
            rm -rf "$TOP_DIR"
        fi
        
        mkdir -p "$(dirname "$STUB_FILE")"
        echo "<?php" > "$STUB_FILE"
    done

    # 3. 物理删除其他确认无 require 钩子的包
    rm -rf larastan hamcrest sebastian phar-io theseer barryvdh

    # 4. 语言包精简：只留 中/英/日 (resources 瘦身大头)
    cd /var/www/html/resources/lang
    find . -maxdepth 1 -type d ! -name "." ! -name "en_US" ! -name "zh_CN" ! -name "ja_JP" -exec rm -rf {} +
    
    # 清理前端源码
    rm -rf /var/www/html/resources/assets

    # 5. 全量碎屑大扫除 (无差别清理 tests, docs, md 等)
    cd /var/www/html/vendor
    find . -type d \( -name "tests" -o -name "test" -o -name "docs" -o -name ".github" -o -name "examples" \) -exec rm -rf {} + && \
    find . -type f \( -name "*.md" -o -name "*.txt" -o -name "LICENSE*" -o -name ".gitignore" -o -name "phpunit.xml*" -o -name ".editorconfig" \) -delete

    # 6. 最终统计
    SIZE_AFTER=$(du -sm . | cut -f1)
    echo "------------------------------------------------"
    echo "  Cleanup Result: $SIZE_BEFORE MB -> $SIZE_AFTER MB"
    echo "  Saved: $((SIZE_BEFORE - SIZE_AFTER)) MB"
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
