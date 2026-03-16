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
    php85-session php85-tokenizer php85-dom php85-simplexml php85-xmlwriter php85-openssl php85-phar \
    && apk del python3 \
    && ln -s /usr/bin/php85 /usr/bin/php \
    && rm -rf /var/cache/apk/*

COPY --from=builder --chown=nobody:nobody /app /var/www/html

RUN <<EOF
    set -e
    cd /var/www/html

    # 1. 准备 Composer
    curl -sS https://getcomposer.org/composer-stable.phar -o composer.phar

    # 2. 【关键】在物理删除前先生成“干净”的索引
    # 这一步会根据 release 原有的 composer.json 生成不含 dev 依赖的加载器
    # 此时文件都还在，所以 dump 过程不会报错
    php composer.phar dump-autoload --no-dev --optimize --classmap-authoritative

    # 3. 物理清理：只删确定没用的“外围”大户
    # 注意：这里去掉了可能导致核心崩溃的目录（如 fruitcake, barryvdh 等）
    cd vendor
    rm -rf \
        rector/ phpstan/ larastan/ fakerphp/ mockery/ \
        hamcrest/ sebastian/ phar-io/ theseer/ \
        phpunit/ nunomaduro/collision \
        spatie/backtrace spatie/flare-client-php \
        spatie/ignition spatie/laravel-ignition

    # 4. 【重要】find 清理时跳过关键文件
    # 绝对不要删除 composer.json，否则 Laravel 的某些组件在运行时解析会失败
    find . -type d \( -name "tests" -o -name "docs" -o -name ".github" \) -exec rm -rf {} +
    find . -type f \( -name "*.md" -o -name "*.txt" -o -name "LICENSE*" -o -name ".gitignore" \) -delete

    # 5. 收尾
    cd /var/www/html
    rm composer.phar
    apk del php85-phar
EOF



COPY config/nginx.conf /etc/nginx/nginx.conf
COPY config/conf.d /etc/nginx/conf.d/
ENV PHP_INI_DIR=/etc/php85
COPY config/fpm-pool.conf ${PHP_INI_DIR}/php-fpm.d/www.conf
COPY config/php.ini ${PHP_INI_DIR}/conf.d/custom.ini
COPY config/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

RUN chown -R nobody:nobody /var/www/html /run /var/lib/nginx /var/log/nginx

USER nobodyE 8080

HEALTHCHECK --timeout=10s CMD curl --silent --fail http://127.0.0.1:8080/fpm-ping || exit 1

CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf"]
