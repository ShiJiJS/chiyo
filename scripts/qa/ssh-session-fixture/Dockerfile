FROM chiyo-synthetic-ssh:a09
RUN apt-get update && apt-get install -y --no-install-recommends sudo && rm -rf /var/lib/apt/lists/* \
 && printf 'fixture:synthetic-login-only\nroot:synthetic-sudo-only\n' | chpasswd \
 && printf 'Defaults:fixture rootpw\nfixture ALL=(ALL) ALL\nfixture ALL=(ALL) NOPASSWD: /usr/bin/true\n' > /etc/sudoers.d/chiyo-fixture \
 && chmod 440 /etc/sudoers.d/chiyo-fixture
COPY start.py /fixture/start.py
COPY sshd_config /fixture/sshd_config
