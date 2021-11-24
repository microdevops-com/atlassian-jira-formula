{% from 'atlassian-jira/map.jinja' import jira with context %}

nginx_install:
  pkg.installed:
    - pkgs:
      - nginx

nginx_files_1:
  file.managed:
    - name: /etc/nginx/nginx.conf
    - contents: |
        worker_processes 4;
        worker_rlimit_nofile 40000;
        events {
            worker_connections 8192;
            use epoll;
            multi_accept on;
        }
        http {
            include /etc/nginx/mime.types;
            default_type application/octet-stream;
            sendfile on;
            tcp_nopush on;
            tcp_nodelay on;
            gzip on;
            gzip_comp_level 4;
            gzip_types text/plain text/css application/x-javascript text/xml application/xml application/xml+rss text/javascript;
            gzip_vary on;
            gzip_proxied any;
            client_max_body_size 1000m;
            server {
                listen 80;
                return 301 https://$host$request_uri;
            }
            server {
                listen 443 ssl;
                server_name {{ pillar["atlassian-jira"]["http_proxyName"] }};
                ssl_certificate /opt/acme/cert/atlassian-jira_{{ pillar["atlassian-jira"]["http_proxyName"] }}_fullchain.cer;
                ssl_certificate_key /opt/acme/cert/atlassian-jira_{{ pillar["atlassian-jira"]["http_proxyName"] }}_key.key;
                client_max_body_size 200M;
                client_body_buffer_size 128k;
                location / {
                    proxy_pass http://localhost:{{ pillar["atlassian-jira"]["http_port"] }};
                    proxy_set_header X-Forwarded-Host $host;
                    proxy_set_header X-Forwarded-Server $host;
                    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                }
            }
        }

nginx_files_2:
  file.absent:
    - name: /etc/nginx/sites-enabled/default

nginx_cert:
  cmd.run:
    - shell: /bin/bash
    - name: "/opt/acme/home/{{ pillar["atlassian-jira"]["acme_account"] }}/verify_and_issue.sh atlassian-jira {{ pillar["atlassian-jira"]["http_proxyName"] }}"

nginx_reload:
  cmd.run:
    - runas: root
    - name: service nginx configtest && service nginx restart

nginx_reload_cron:
  cron.present:
    - name: /usr/sbin/service nginx configtest && /usr/sbin/service nginx restart
    - identifier: nginx_reload
    - user: root
    - minute: 15
    - hour: 6

jira-dependencies:
  pkg.installed:
    - pkgs:
      - libxslt1.1
      - xsltproc
      - openjdk-11-jdk

jira:
  file.managed:
    - name: /etc/systemd/system/atlassian-jira.service
    - source: salt://atlassian-jira/files/atlassian-jira.service
    - template: jinja
    - defaults:
        config: {{ jira|json }}

  module.wait:
    - name: service.systemctl_reload
    - watch:
      - file: jira

  group.present:
    - name: {{ jira.group }}

  user.present:
    - name: {{ jira.user }}
    - home: {{ jira.dirs.home }}
    - gid: {{ jira.group }}
    - require:
      - group: jira
      - file: jira-dir

  service.running:
    - name: atlassian-jira
    - enable: True
    - require:
      - file: jira

jira-graceful-down:
  service.dead:
    - name: atlassian-jira
    - require:
      - module: jira
    - prereq:
      - file: jira-install

jira-install:
  archive.extracted:
    - name: {{ jira.dirs.extract }}
    - source: {{ jira.url }}
    - source_hash: {{ jira.url_hash }}
    - options: z
    - if_missing: {{ jira.dirs.current_install }}
    - keep: True
    - require:
      - file: jira-extractdir

  file.symlink:
    - name: {{ jira.dirs.install }}
    - target: {{ jira.dirs.current_install }}
    - require:
      - archive: jira-install
    - watch_in:
      - service: jira

jira-server-xsl:
  file.managed:
    - name: {{ jira.dirs.temp }}/server.xsl
    - source: salt://atlassian-jira/files/server.xsl
    - template: jinja
    - require:
      - file: jira-temptdir

  cmd.run:
    - name: |
        xsltproc --stringparam pHttpPort "{{ jira.get('http_port', '') }}" \
          --stringparam pHttpScheme "{{ jira.get('http_scheme', '') }}" \
          --stringparam pHttpProxyName "{{ jira.get('http_proxyName', '') }}" \
          --stringparam pHttpProxyPort "{{ jira.get('http_proxyPort', '') }}" \
          --stringparam pAjpPort "{{ jira.get('ajp_port', '') }}" \
          --stringparam pAccessLogFormat "{{ jira.get('access_log_format', '').replace('"', '\\"') }}" \
          -o {{ jira.dirs.temp }}/server.xml {{ jira.dirs.temp }}/server.xsl server.xml
    - cwd: {{ jira.dirs.install }}/conf
    - require:
      - file: jira-install
      - file: jira-server-xsl

jira-server-xml:
  file.managed:
    - name: {{ jira.dirs.install }}/conf/server.xml
    - source: {{ jira.dirs.temp }}/server.xml
    - require:
      - cmd: jira-server-xsl
    - watch_in:
      - service: jira

jira-dir:
  file.directory:
    - name: {{ jira.dir }}
    - user: root
    - group: root
    - mode: 755
    - makedirs: True

jira-home:
  file.directory:
    - name: {{ jira.dirs.home }}
    - user: {{ jira.user }}
    - group: {{ jira.group }}
    - mode: 755
    - require:
      - file: jira-dir
    - makedirs: True

jira-extractdir:
  file.directory:
    - name: {{ jira.dirs.extract }}
    - use:
      - file: jira-dir

jira-temptdir:
  file.directory:
    - name: {{ jira.dirs.temp }}
    - use:
      - file: jira-dir

jira-scriptdir:
  file.directory:
    - name: {{ jira.dirs.scripts }}
    - use:
      - file: jira-dir

{% for file in [ 'env.sh', 'start.sh', 'stop.sh' ] %}
jira-script-{{ file }}:
  file.managed:
    - name: {{ jira.dirs.scripts }}/{{ file }}
    - source: salt://atlassian-jira/files/{{ file }}
    - user: {{ jira.user }}
    - group: {{ jira.group }}
    - mode: 755
    - template: jinja
    - defaults:
        config: {{ jira|json }}
    - require:
      - file: jira-scriptdir
      - group: jira
      - user: jira
    - watch_in:
      - service: jira
{% endfor %}

{% if jira.get('crowd') %}
jira-crowd-properties:
  file.managed:
    - name: {{ jira.dirs.install }}/atlassian-jira/WEB-INF/classes/crowd.properties
    - require:
      - file: jira-install
    - watch_in:
      - service: jira
    - contents: |
{%- for key, val in jira.crowd.items() %}
        {{ key }}: {{ val }}
{%- endfor %}
{% endif %}

{% if jira.managedb %}
jira-dbconfig:
  file.managed:
    - name: {{ jira.dirs.home }}/dbconfig.xml
    - source: salt://atlassian-jira/files/dbconfig.xml
    - template: jinja
    - user: {{ jira.user }}
    - group: {{ jira.group }}
    - mode: 640
    - defaults:
        config: {{ jira|json }}
    - require:
      - file: jira-home
    - watch_in:
      - service: jira
{% endif %}

{% for chmoddir in ['bin', 'work', 'temp', 'logs'] %}
jira-permission-{{ chmoddir }}:
  file.directory:
    - name: {{ jira.dirs.install }}/{{ chmoddir }}
    - user: {{ jira.user }}
    - group: {{ jira.group }}
    - recurse:
      - user
      - group
    - require:
      - file: jira-install
      - group: jira
      - user: jira
    - require_in:
      - service: jira
{% endfor %}

jira-disable-JiraSeraphAuthenticator:
  file.blockreplace:
    - name: {{ jira.dirs.install }}/atlassian-jira/WEB-INF/classes/seraph-config.xml
    - marker_start: 'CROWD:START - The authenticator below here will need to be commented'
    - marker_end: '<!-- CROWD:END'
    - content: {% if jira.crowdSSO %}'    <!-- <authenticator class="com.atlassian.jira.security.login.JiraSeraphAuthenticator"/> -->'{% else %}'    <authenticator class="com.atlassian.jira.security.login.JiraSeraphAuthenticator"/>'{% endif %}
    - require:
      - file: jira-install
    - watch_in:
      - service: jira

jira-enable-SSOSeraphAuthenticator:
  file.blockreplace:
    - name: {{ jira.dirs.install }}/atlassian-jira/WEB-INF/classes/seraph-config.xml
    - marker_start: 'CROWD:START - If enabling Crowd SSO integration uncomment'
    - marker_end: '<!-- CROWD:END'
    - content: {% if jira.crowdSSO %}'    <authenticator class="com.atlassian.jira.security.login.SSOSeraphAuthenticator"/>'{% else %}'    <!-- <authenticator class="com.atlassian.jira.security.login.SSOSeraphAuthenticator"/> -->'{% endif %}
    - require:
      - file: jira-install
    - watch_in:
      - service: jira