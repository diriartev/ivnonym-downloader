# 🔐 Política de seguridad

## Reportar una vulnerabilidad

No abras un *issue* público. Usa **Security → Report a vulnerability** en este repositorio (reporte privado).
Respondo lo antes posible.

## Cómo se protege este proyecto

- **Ningún secreto guardado**: el pipeline publica con el token temporal de GitHub y firma con Sigstore (sin llaves).
- Cada push pasa por **gitleaks** (todo el historial), **ruff + bandit**, **shellcheck**, **hadolint**, **actionlint**, **trivy** (configuración e imagen) y pruebas reales sobre el contenedor endurecido.
- Las acciones de GitHub y las herramientas están fijadas por **hash de commit / digest**.
- Las publicaciones requieren **aprobación manual** (entorno `produccion`) y se firman; cualquiera puede verificarlas con `cosign verify` (ver las notas de cada Release).
