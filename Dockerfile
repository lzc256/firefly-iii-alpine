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
    # 注意：这里 phpstan, rector 等现在直接指向根目录，会把下面所有子包一并删掉
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
    thecodingmachine:thecodingmachine/safe/lib/special_cases.php
    "

    # 2. 核心循环
    for ENTRY in $PKGS; do
        TOP_DIR=${ENTRY%%:*}
        STUB_FILE=${ENTRY#*:}
        
        # 如果有根目录定义，直接整块物理抹除
        if [ -n "$TOP_DIR" ]; then
            rm -rf "$TOP_DIR"
        fi
        
        mkdir -p "$(dirname "$STUB_FILE")"
        echo "<?php" > "$STUB_FILE"
    done

    # 3. 针对 thecodingmachine 的批量补丁 (解决那几十个 generated/*.php)
    # 用一行 shell 循环直接生成所有可能的桩文件，防止 Fatal Error
    SAFE_DIR="thecodingmachine/safe/generated"
    mkdir -p "$SAFE_DIR"
    for f in apache apcu array datetime dir errorfunc fpm hash json mysql network password pcntl pcre reflection session url; do
        echo "<?php" > "$SAFE_DIR/$f.php"
    done

    # 4. 暴力清理其他已知的大户
    rm -rf larastan hamcrest sebastian phar-io theseer barryvdh

    # 5. 语言包深度精简 (只留 zh_CN, en_US, ja_JP)
    cd /var/www/html/resources/lang
    find . -maxdepth 1 -type d ! -name "." ! -name "en_US" ! -name "zh_CN" ! -name "ja_JP" -exec rm -rf {} +
    
    # 清理前端源码
    rm -rf /var/www/html/resources/assets

    # 6. 全量碎屑大扫除
    cd /var/www/html/vendor
    find . -type d \( -name "tests" -o -name "test" -o -name "docs" -o -name ".github" -o -name "examples" \) -exec rm -rf {} + && \
    find . -type f \( -name "*.md" -o -name "*.txt" -o -name "LICENSE*" -o -name ".gitignore" -o -name "phpunit.xml*" -o -name ".editorconfig" \) -delete

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
