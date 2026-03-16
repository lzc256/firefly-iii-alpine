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

    # 1. 初始大小统计
    SIZE_BEFORE=$(du -sm . | cut -f1)

    # 2. 核心名单：[顶级目录]:[需要复活的入口文件相对路径]
    # 只要出现在冒号前的目录，都会被整块物理删除
    PKGS="
    phpstan:phpstan/bootstrap.php
    rector:rector/bootstrap.php
    mockery:mockery/library/helpers.php
    mockery:mockery/library/Mockery.php
    fakerphp:faker/src/Faker/Factory.php
    spatie:flare-client-php/src/helpers.php
    spatie:laravel-ignition/src/helpers.php
    nunomaduro:collision/src/Adapters/Phpunit/Autoload.php
    phpunit:phpunit/src/Framework/Assert/Functions.php
    "

    # 3. 单个 For 循环搞定“爆破”与“复活”
    for ENTRY in $PKGS; do
        TOP_DIR=${ENTRY%%:*}   # 拿到冒号前的顶级目录，如 phpstan
        STUB_FILE=${ENTRY#*:}   # 拿到冒号后的完整路径，如 phpstan/bootstrap.php
        
        # 物理爆破：管它里面有多少兆，直接推平
        rm -rf "$TOP_DIR"
        
        # 精准复活：重建入口，骗过加载器
        mkdir -p "$(dirname "$STUB_FILE")"
        echo "<?php" > "$STUB_FILE"
    done

    # 4. 补刀：删除没有 Hook 文件的纯开发垃圾
    rm -rf larastan hamcrest sebastian phar-io theseer barryvdh thecodingmachine

    # 5. 极致清理： tests/docs
    find . -maxdepth 3 -type d \( -name "tests" -o -name "docs" -o -name ".github" \) -exec rm -rf {} +

    # 6. 成果展示
    SIZE_AFTER=$(du -sm . | cut -f1)
    echo "----------------------------------------"
    echo "  Cleanup Result: $SIZE_BEFORE MB -> $SIZE_AFTER MB"
    echo "  Space Saved: $((SIZE_BEFORE - SIZE_AFTER)) MB"
    echo "----------------------------------------"

    # 7. 彻底移除 Python (现在已经不需要它了)
    cd /
    apk del curl unzip || true
    rm -rf /var/cache/apk/*
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
