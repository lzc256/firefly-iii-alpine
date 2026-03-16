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
    cd /var/www/html/vendor

    # 1. 定义需要“物理抹除”但保留“空文件占位”的开发依赖及其入口文件
    # 格式: "目录名:辅助函数文件路径"
    PKGS="
    spatie/flare-client-php:src/helpers.php
    spatie/laravel-ignition:src/helpers.php
    nunomaduro/collision:src/Adapters/Phpunit/Autoload.php
    phpunit/phpunit:src/Framework/Assert/Functions.php
    mockery/mockery:library/helpers.php
    rector/rector:bootstrap.php
    phpstan/phpstan:bootstrap.php
    "

    # 2. 执行循环：删掉整个目录，然后精准重建空壳
    for ENTRY in $PKGS; do
        DIR=${ENTRY%%:*}
        FILE=${ENTRY#*:}
        
        if [ -d "$DIR" ]; then
            rm -rf "$DIR"
            # 重建路径并创建 0 字节文件，彻底堵住 "Failed to open stream" 报错
            mkdir -p "$(dirname "$DIR/$FILE")"
            touch "$DIR/$FILE"
        fi
    done

    # 3. 顺便砍掉其他没有辅助函数干扰的“大户”
    rm -rf \
        larastan/ fakerphp/ hamcrest/ sebastian/ \
        phar-io/ theseer/ barryvdh/

    # 4. 极致清理：只删目录不删文件（处理 tests, docs 等）
    find . -maxdepth 3 -type d \( -name "tests" -o -name "docs" -o -name ".github" \) -exec rm -rf {} +

    # 5. 系统收尾：保住 Python (Supervisor 需要它)
    cd /
    apk del curl unzip || true
    rm -rf /var/cache/apk/*
EOF


COPY config/nginx.conf /etc/nginx/nginx.conf
COPY config/conf.d /etc/nginx/conf.d/
ENV PHP_INI_DIR=/etc/php85
COPY config/fpm-pool.conf ${PHP_INI_DIR}/php-fpm.d/www.conf
COPY config/php.ini ${PHP_INI_DIR}/conf.d/custom.ini
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

RUN chown -R nobody:nobody /var/www/html /run /var/lib/nginx /var/log/nginx

USER nobody

HEALTHCHECK --timeout=10s CMD curl --silent --fail http://127.0.0.1:8080/fpm-ping || exit 1

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
