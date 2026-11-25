# AwayFromShorts 2.1.3

- 修复覆盖升级后，常驻时间限额任务仍使用旧版内存代码的问题。
- `AwayFromShorts-GameQuota` 重新注册时会先停止旧实例，再启动新实例。
- `AwayFromShorts-WebUI` 重新注册时也会先停止旧实例，避免升级后继续提供旧接口。
- 新版后台会实际写入星期生效信息，而不是只在网页接口中临时计算。
