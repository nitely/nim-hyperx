install_mkcert:
	apt update && \
	apt install -y curl libnss3-tools && \
	rm -f ./mkcert-v1.4.4-linux-amd64 && \
	curl -JLO "https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64" && \
	chmod +x mkcert-v*-linux-amd64 && \
	cp -rf mkcert-v*-linux-amd64 /usr/local/bin/mkcert

.PHONY: install_mkcert
