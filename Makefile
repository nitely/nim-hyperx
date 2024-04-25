install_mkcert:
	apt update && \
	apt install -y curl libnss3-tools && \
	curl -JLO "https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-amd64" && \
	chmod +x mkcert-v*-linux-amd64 && \
	cp -rf mkcert-v*-linux-amd64 /usr/local/bin/mkcert && \
	mkcert -install && \
	mkcert example.com "*.example.com" example.test localhost 127.0.0.1 ::1

.PHONY: install_mkcert
