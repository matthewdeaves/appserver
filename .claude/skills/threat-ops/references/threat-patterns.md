# Threat Patterns Reference

## Known Scanner Paths

Requests to these paths indicate automated scanning tools probing for vulnerabilities.

### WordPress

- `/wp-admin`, `/wp-login.php`, `/wp-content`, `/wp-includes`, `/xmlrpc.php`
- Severity: Medium (ubiquitous, low-effort scanning)

### Configuration Files

- `/.env`, `/.git`, `/.git/config`, `/.svn`, `/.htaccess`, `/.htpasswd`, `/.DS_Store`
- `/config.yml`, `/config.json`, `/composer.json`, `/package.json`, `/Dockerfile`
- Severity: High (actively seeking secrets/source code)

### Admin Panels

- `/phpmyadmin`, `/adminer`, `/admin`, `/cpanel`, `/webmail`
- `/manager/html` (Tomcat), `/jenkins`, `/telescope` (Laravel)
- Severity: Medium-High

### Shell/Command Access

- `/shell`, `/cmd`, `/console`, `/terminal`, `/cgi-bin`
- Severity: High (seeking RCE)

### Known CVE Targets

- `/solr/` (Apache Solr), `/actuator` (Spring Boot), `/api/v1/pods` (Kubernetes)
- `/debug`, `/trace`, `/server-status`, `/server-info` (Apache)
- `/swagger`, `/phpinfo`
- Severity: High

### Traversal Patterns

- `../`, `..%2f`, `..%2F`, `..%252f`, `..%252F`
- Severity: Critical (active exploitation attempt)

## Scanner User Agent Signatures

### Dedicated Security Tools (always malicious against targets not being tested)

| Tool | UA Pattern | Category |
|------|-----------|----------|
| sqlmap | `sqlmap` | SQL injection scanner |
| Nikto | `nikto` | Web server scanner |
| Nmap | `nmap` | Network scanner |
| Masscan | `masscan` | Port scanner |
| ZGrab | `zgrab` | TLS/HTTP grabber |
| Nuclei | `nuclei` | Vulnerability scanner |
| DirBuster | `dirbuster` | Directory brute-forcer |
| GoBuster | `gobuster` | Directory brute-forcer |
| ffuf | `ffuf` | Fuzzer |
| wfuzz | `wfuzz` | Fuzzer |
| Hydra | `hydra` | Brute-force tool |
| Medusa | `medusa` | Brute-force tool |
| w3af | `w3af` | Web app scanner |
| Skipfish | `skipfish` | Web app scanner |
| Arachni | `arachni` | Web app scanner |
| Acunetix | `acunetix` | Commercial scanner |
| Nessus | `nessus` | Vulnerability scanner |
| OpenVAS | `openvas` | Vulnerability scanner |
| Burp Suite | `burpsuite` | Proxy/scanner |

### Suspicious Generic Agents

| Pattern | Risk Level | Notes |
|---------|-----------|-------|
| `python-requests` | Low-Medium | Could be legitimate automation |
| `Go-http-client` | Low-Medium | Could be legitimate service |
| `curl/` | Low | Only suspicious with no referer + scanning paths |

## Severity Assignment Rules

| Condition | Severity |
|-----------|----------|
| Traversal pattern + any 200 response | Critical |
| Auth brute force with some 200s | Critical |
| >500 requests + multiple attack categories | High |
| Known scanner UA + >50 requests | High |
| Scanner paths + >90% error responses | Medium-High |
| 50-500 requests, single category | Medium |
| <50 requests, common scanner patterns | Low |
| Unusual but not clearly malicious | Info |

## Detection Thresholds

| Metric | Threshold | Action |
|--------|-----------|--------|
| Requests per IP | >100 in window | Flag as high_rate |
| Error response ratio | >90% | Indicator of scanning |
| Scanner paths hit | >3 unique | Likely automated scan |
| Auth endpoint requests | >20 in 1h | Possible brute force |
| Unique 404 paths | >50 from single IP | Directory enumeration |
