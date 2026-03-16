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
    SIZE_BEFORE=$(du -sm . | cut -f1)
    cd /var/www/html/vendor

    # 1. 扩充名单：不仅包含 helpers，还包含那些被 require 强制钩住的入口文件
    PKGS="
    spatie/flare-client-php:src/helpers.php
    spatie/laravel-ignition:src/helpers.php
    nunomaduro/collision:src/Adapters/Phpunit/Autoload.php
    phpunit/phpunit:src/Framework/Assert/Functions.php
    mockery/mockery:library/helpers.php
    mockery/mockery:library/Mockery.php
    rector/rector:bootstrap.php
    phpstan/phpstan:bootstrap.php
    fakerphp/faker:src/Faker/Factory.php
    "

    # 2. 依然是那个循环：删目录 -> 建路径 -> 填空文件
    for ENTRY in $PKGS; do
        DIR=${ENTRY%%:*}
        FILE=${ENTRY#*:}
        
        if [ -d "$DIR" ]; then
            # 只有第一次处理该目录时才删除
            [ -f "$DIR/$FILE" ] || rm -rf "$DIR" 
            
            mkdir -p "$(dirname "$DIR/$FILE")"
            touch "$DIR/$FILE"
            # 写入一个基础的 PHP 开始标签，防止某些环境开启了 strict_types 导致空文件报错
            echo "<?php" > "$DIR/$FILE"
        fi
    done

    # 3. 这里的包没有 require 钩子，可以直接物理抹除
    rm -rf \
        larastan/ hamcrest/ sebastian/ \
        phar-io/ theseer/ barryvdh/

    # 4. 极致清理：只删目录不删文件
    find . -maxdepth 3 -type d \( -name "tests" -o -name "docs" -o -name ".github" \) -exec rm -rf {} +

    # 5. 系统收尾 (确保 Supervisor 正常)
    cd /
    apk del curl unzip || true
    rm -rf /var/cache/apk/*

    cd /var/www/html
    SIZE_AFTER=$(du -sm . | cut -f1)
    SAVED=$((SIZE_BEFORE - SIZE_AFTER))
    echo "  Before: ${SIZE_BEFORE} MB"
    echo "  After:  ${SIZE_AFTER} MB"
    echo "  Saved:  ${SAVED} MB"
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
