FROM python@sha256:a1165e272e578941b84abc79e4ab38a0305cd12803a5c4247979ac7655f4d641
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server && rm -rf /var/lib/apt/lists/* && useradd -m fixture && passwd -d fixture
COPY sshd_config /fixture/sshd_config
COPY start.py /fixture/start.py
ENTRYPOINT ["python", "/fixture/start.py"]
