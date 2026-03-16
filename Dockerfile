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

    # 1. 物理删除：砍掉大户
    rm -rf \
        rector/ phpstan/ larastan/ fakerphp/ mockery/ hamcrest/ \
        sebastian/ phar-io/ theseer/ phpunit/ \
        nunomaduro/collision spatie/backtrace \
        spatie/flare-client-php spatie/ignition \
        spatie/laravel-ignition fruitcake/laravel-debugbar

    # 2. 逻辑删除：在 autoload_files.php 中删掉指向已删除目录的行
    # 我们只删包含特定关键字的行，这样 laravel/framework 和 symfony/ 的核心函数会被保留
    if [ -f composer/autoload_files.php ]; then
        sed -i '/phpstan/d' composer/autoload_files.php
        sed -i '/phpunit/d' composer/autoload_files.php
        sed -i '/mockery/d' composer/autoload_files.php
        sed -i '/rector/d' composer/autoload_files.php
        sed -i '/spatie\/flare-client-php/d' composer/autoload_files.php
        sed -i '/spatie\/ignition/d' composer/autoload_files.php
        sed -i '/laravel-ignition/d' composer/autoload_files.php
        sed -i '/laravel-debugbar/d' composer/autoload_files.php
        sed -i '/nunomaduro\/collision/d' composer/autoload_files.php
    fi

    # 3. 对 autoload_static.php 做同样的清理（这是为了兼容 opcache 开启的情况）
    if [ -f composer/autoload_static.php ]; then
        sed -i '/phpstan/d' composer/autoload_static.php
        sed -i '/phpunit/d' composer/autoload_static.php
        sed -i '/mockery/d' composer/autoload_static.php
        sed -i '/rector/d' composer/autoload_static.php
        sed -i '/spatie\/flare-client-php/d' composer/autoload_static.php
        sed -i '/spatie\/ignition/d' composer/autoload_static.php
        sed -i '/laravel-ignition/d' composer/autoload_static.php
        sed -i '/laravel-debugbar/d' composer/autoload_static.php
        sed -i '/nunomaduro\/collision/d' composer/autoload_static.php
    fi

    # 4. 清理碎屑
    find . -maxdepth 3 -type d \( -name "tests" -o -name "docs" -o -name ".github" \) -exec rm -rf {} +
    
    # 5. 系统清理
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
