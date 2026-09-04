#!/usr/bin/env bash
set -euo pipefail

CERT_NAME="VoiceIME-Dev"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
TEMP_DIR="$(mktemp -d)"

trap 'rm -rf "${TEMP_DIR}" /tmp/voiceime_cert.pem' EXIT

echo "=== コード署名用自己署名証明書 (${CERT_NAME}) をセットアップします ==="

# 既に有効な証明書が存在するか確認
if security find-identity -v -p codesigning | grep -q "${CERT_NAME}"; then
    echo "既に有効な ${CERT_NAME} 証明書が存在します。"
    security find-identity -v -p codesigning
    exit 0
fi

# OpenSSL 設定ファイル（コード署名拡張用）
cat > "${TEMP_DIR}/openssl.cnf" << 'EOF'
[ req ]
default_bits        = 2048
distinguished_name  = req_distinguished_name
prompt              = no
x509_extensions     = v3_codesign

[ req_distinguished_name ]
CN = VoiceIME-Dev
O  = VoiceIME Local Development

[ v3_codesign ]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
EOF

# 秘密鍵と自己署名証明書の生成
echo "-> 秘密鍵と自己署名証明書を生成中..."
openssl req -new -x509 -newkey rsa:2048 -nodes \
    -keyout "${TEMP_DIR}/key.pem" \
    -out "${TEMP_DIR}/cert.pem" \
    -days 3650 \
    -config "${TEMP_DIR}/openssl.cnf"

# PKCS12 バンドル作成 (-legacy は macOS SecKeychainItemImport 互換用)
echo "-> PKCS#12 に変換中..."
openssl pkcs12 -export \
    -legacy \
    -inkey "${TEMP_DIR}/key.pem" \
    -in "${TEMP_DIR}/cert.pem" \
    -out "${TEMP_DIR}/cert.p12" \
    -passout pass:temporary_voiceime_pass

# Keychain にインポート
echo "-> macOS Keychain (login.keychain) へ登録中..."
security import "${TEMP_DIR}/cert.p12" \
    -k "${KEYCHAIN}" \
    -P temporary_voiceime_pass \
    -T /usr/bin/codesign

# コード署名として信頼
echo "-> コード署名ポリシーとして信頼登録中..."
cp "${TEMP_DIR}/cert.pem" /tmp/voiceime_cert.pem
security add-trusted-cert -d -r trustRoot -p codeSign -k "${KEYCHAIN}" /tmp/voiceime_cert.pem

echo "=== 証明書のセットアップが完了しました！ ==="
security find-identity -v -p codesigning
