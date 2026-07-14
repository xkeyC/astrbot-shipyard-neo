# Shared Browser Pool — Design Document

> 版本：v1 （草稿）
> 日期：2026-06-05
> 状态：设计阶段，对齐中

---

## 1. 动机

### 1.1 现状

当前 `browser-python` profile 每个沙箱都会创建独立的 Gull 容器，里面跑一个完整 Chromium 进程。

```
Sandbox A  →  Ship  (python/shell)
           →  Gull  →  Chromium ① (~500MB)

Sandbox B  →  Ship  (python/shell)
           →  Gull  →  Chromium ② (~500MB)
```

| 沙箱数 | 浏览器内存 | 可行性 |
|:--:|:--:|:--:|
| 1 | 500MB | ✅ |
| 3 | 1.5GB | ⚠️ |
| 10 | 5GB | ❌ |
| 100 | 50GB | 不可能 |

### 1.2 目标

**一台机器只跑一个 Chromium 进程，所有沙箱共享。** 每个沙箱通过 Playwright Browser Context 隔离，额外开销从 500MB 降到 ~15MB。

---

## 2. 架构

### 2.1 总览

```
┌────────────────── Gull Service （唯一, 常驻容器）──────────────────┐
│  agent-browser daemon → Playwright → Chromium (~500MB)              │
│                                                                     │
│  SessionManager                                                      │
│  ├─ sandbox-A → BrowserContext ① (cookies, tabs, storage)           │
│  ├─ sandbox-B → BrowserContext ②                                    │
│  └─ sandbox-C → BrowserContext ③                                    │
│                                                                     │
│  API:                                                                │
│    POST   /sessions              → create & return context           │
│    DELETE /sessions/{sandbox_id} → destroy context (persist first)   │
│    GET    /sessions              → list active sessions (for GC)     │
│    POST   /exec                  → execute command in context        │
└─────────────────────────────────────────────────────────────────────┘
```

```yaml
# docker-compose 部署
services:
  gull-service:     # ← 常驻，不跟随沙箱生命周期
    image: shipyard-neo/gull:dev
    restart: unless-stopped

  bay:              # ← 控制面，不再为浏览器能力创建 gull 容器
    environment:
      - BAY_BROWSER_SERVICE_ENDPOINT=http://gull-service:8115
```

### 2.2 隔离模型

| 维度 | 机制 | 隔离程度 |
|------|------|:--:|
| cookies / localStorage | Playwright BrowserContext | 完全隔离 |
| 网络 / 代理 | Playwright Context 级 | 完全隔离 |
| 打开的标签页 | 每个 Context 独立 | 完全隔离 |
| GPU 进程 | 共享 Chromium 进程 | 一崩全崩 |
| 内存 / CPU | 共享 | 一卡全卡 |

Playwright BrowserContext 是为多租户场景设计的——Playwright 官方文档明确 BrowserContext 可用于"parallel testing with isolated sessions"。对于 AI Agent 场景（同租户、非对抗），Context 级隔离足够。

**与 Firecracker / VM 级隔离的区别**：Chrome 的 0day 漏洞理论上可跨 Context 逃逸。但所有浏览器命令都跑在 Docker 容器内，逃逸到主机需要再突破 Docker 隔离。v1 不将浏览器间攻击列入威胁模型。

---

## 3. Session 生命周期

### 3.1 状态机

```
   创建沙箱       首次使用浏览器        闲置 > TTL          沙箱销毁
[NONE] ────→ [ACTIVE] ◄──────── (复用) ────→ [EXPIRED] ────→ [DESTROYED]
                  │                      auto-GC             │
                  │ Chrome 崩溃                               │ 持久化 state.json
                  ↓                                           ↓
              [BROKEN] ──→ 下次请求自动重建 ──→ [ACTIVE]      [DESTROYED]
```

### 3.2 懒加载

沙箱创建时**不创建** BrowserContext。第一次浏览器命令到达 Gull 时才 `get_or_create`。对于从不使用浏览器能力的沙箱，零开销。

### 3.3 闲置回收

Gull 后台 GC 线程每 5 分钟扫描一次：销毁闲置超过 10 分钟且无活跃命令的 Context。销毁前将 cookies + localStorage 写入持久化存储。

### 3.4 沙箱销毁联动

```
Bay 删除沙箱 ──→ Bay 调 Gull DELETE /sessions/{sandbox_id}
                 → Gull 关闭 Context → 写 state.json → 删目录
```

若网络故障 Bay 调不到 Gull：Gull 兜底 GC（24h 无引用硬删）。

---

## 4. 并发控制

### 4.1 同沙箱并发命令

Per-session `asyncio.Lock`。同一沙箱同时发两个浏览器命令 → 第二个排队。不区分命令类型（v1）。

### 4.2 跨沙箱并发

不同沙箱的 Context 天然并行，Chrome 多 tab/多 context 原生支持。

### 4.3 创建期间重复请求

Context 正在创建中时（`get_or_create` 未返回），第二个请求到达 → 等待第一个创建完成再复用（`asyncio.Event`），不会创建两个 Context。

### 4.4 全局并发上限

`active_commands` 计数器，全局上限（如 50 并发）。超过 → 返回 429，由 Bay/SDK 重试。保护 Chromium 不被压死。

---

## 5. 故障处理

### 5.1 Chrome 崩溃

Gull 检测到 Chrome 进程退出了 → 自动重启 Chrome → 重建所有活跃 Context（从 state.json 恢复 cookies）。3-5 秒窗口期内所有请求返回 503。

重建后 Context 是全新的——cookies 恢复了但打开的 tab 没了。Agent 需要能处理「页面丢失，重新导航」的情况，这属于 Agent 自身的健壮性范畴，不由 Gull 保证。

### 5.2 单个 Context 崩溃

Context 因为 OOM 或 bug 崩溃时，**只影响该沙箱**。Gull 标记该 Context 为 BROKEN → 下次请求来时重建 Context（带 cookies 恢复）。

### 5.3 Gull 完全挂掉

所有沙箱的浏览器能力不可用。Bay 检测 Gull 不可达 → 返回错误给调用方。Gull 重启后自动恢复（Chrome 启动 + 懒加载重建 Context）。依赖 Docker 的 `restart: unless-stopped` 兜底。

### 5.4 命令超时 / 子进程僵死

`agent-browser` 命令超过 `timeout` 秒未返回 → `asyncio.wait_for` 超时 → 强制 `proc.kill()` 清理僵尸进程 → 返回超时错误给 Bay。Context 不受影响。

### 5.5 Gull 重启

全部活跃 Context 丢失，Chrome 重建。Bay 侧无感知——下一次浏览器命令进来时懒加载重建 Context（cookies 从磁盘恢复）。命令多花 ~100ms（创建 Context 的开销）。

### 5.6 Bay 重启

Bay 重启后内存无沙箱列表，Gull 侧仍有活跃 Context。v1 靠 Gull 闲置 GC 自然淘汰。v2 可考虑 Bay 启动时调 `GET /sessions` 校验存活。

---

## 6. 存储

### 6.1 数据分类

| 数据 | 大小 | 持久化 | 存储位置 |
|------|:--:|:--:|------|
| cookies / localStorage | < 1MB | ✅ | `/data/gull/sessions/{sandbox_id}/state.json` |
| 截图 | 100KB-2MB | ❌ | `/tmp/screenshots/`（tmpfs, 即用即删） |
| 下载文件 | 不可控 | ❌ | `/tmp/downloads/`（请求响应中直接返回） |
| 浏览器缓存 | 几十 MB | ❌ | Chromium 内部缓存（不管理） |

### 6.2 持久化方案

Gull Service 独自挂一个持久化卷：

```
/data/gull/sessions/
  sandbox-abc123/
    state.json       ← Playwright storage_state()
  sandbox-def456/
    state.json
```

- **写入时机**：Context 关闭时（销毁 / GC 回收）
- **写入方式**：先写临时文件 → `os.rename`（原子操作），避免半截文件
- **恢复**：Gull 重启后不自动建 Context；下一次浏览器命令到达时按 `sandbox_id` 加载 state.json，创建 Context
- **清理**：沙箱销毁时删除目录；24h 无引用兜底 GC 硬删
- **权限**：`/data/gull/sessions/` 下每个子目录 `700`，仅 gull 用户可读
- **v1 简化**：v1 可暂时不做持久化，cookies 仅存内存。Gull 重启后所有 sandbox 丢登录态，对 AI Agent 场景影响有限

### 6.3 临时文件

- 截图、下载存 `/tmp`（容器内 tmpfs），每次命令执行完成后清理
- 防止磁盘被临时文件撑满

---

## 7. 资源限制

### 7.1 Session 数上限

`max_sessions: 100`。第 101 个请求返回 429，错误信息包含当前负载。

### 7.2 Tab 数上限

`max_tabs_per_session: 20`。超过 → 命令拒绝。防止单个沙箱吃光浏览器资源。

### 7.3 单个命令超时

`command_timeout_default: 30s`，`max: 300s`。

### 7.4 内存监控

v2 考虑。监控 Chrome RSS → 超过阈值发告警 / 触发定期重启（如每 500 个 Context 轮换一次或夜间重启）。

---

## 8. GC 策略

| 策略 | 触发条件 | 动作 |
|------|----------|------|
| **闲置回收** | Context 无活跃命令且闲置 > 10min | 关 Context，持久化，释放 15MB |
| **孤儿清理** | Context 对应 sandbox 在 Bay 中已不存在 > 24h | 关 Context，删磁盘数据 |
| **Gull 启动校验** | v2 可选 | Bay 调 `GET /sessions` 对比存活沙箱，删死 Context |

---

## 9. 安全

### 9.1 Context 隔离

Playwright BrowserContext 提供 cookies / storage / network 的级别隔离。不同 sandbox 无法互相读取浏览器数据。

### 9.2 文件系统隔离

Gull 进程以 `gull` 用户运行，session 数据目录 700 权限。Agent 代码跑在 ship 容器内，无法访问 Gull 的文件系统。

### 9.3 容器隔离

Gull Service、Ship 容器、Bay 均在同一 Docker 网络下但不同容器。Chrome 进程的所有行为局限于 Gull 容器内。

### 9.4 配置安全

`browser_service.enabled: true` 是全局开关。关闭后所有 profile 回退到 per-sandbox 模式，不会遗留共享池数据。

---

## 10. 配置设计

### 10.1 Bay 全局配置

```yaml
# config.yaml 顶层
browser_service:
  enabled: true
  endpoint: "http://gull-service:8115"
```

- `enabled: false` 或整个 block 不写 → 回退到 per-sandbox 模式
- `endpoint` 指向 Gull Service 的 HTTP 地址

### 10.2 Profile 配置

```yaml
profiles:
  # 共享浏览器 — v1 的默认模式
  - id: browser-python
    browser: shared              # 可省略，有 browser capability 时默认为 shared
    containers:
      - name: ship
        capabilities: [python, shell, filesystem, browser]
        image: "shipyard-neo/ship:dev"
    # ← 没有 gull 容器！Bay 不创建它

  # 纯代码 — 不涉及浏览器
  - id: python-default
    containers:
      - name: ship
        capabilities: [python, shell, filesystem]

  # 兜底：强制 per-sandbox 隔离
  - id: browser-isolated
    browser: isolated
    containers:
      - name: ship
      - name: gull
```

`browser` 字段取值：

| 值 | 行为 |
|----|------|
| `shared`（默认） | Bay 不创建 gull 容器，浏览器请求转发到全局 Gull Service |
| `isolated` | 走老逻辑，per-sandbox gull 容器 |

### 10.3 Gull 配置

```yaml
# gull 环境变量 / config
GULL_MODE: shared            # single | shared
GULL_MAX_SESSIONS: 100
GULL_SESSION_IDLE_TTL: 600  # 秒
GULL_GC_INTERVAL: 300
GULL_STORAGE_ROOT: /data/gull/sessions
```

---

## 11. 兼容性

### 11.1 向后兼容

- 老 profile（无 `browser` 字段但有 gull 容器）→ 保持 per-sandbox 逻辑，不受影响
- profile 有 browser capability 但既无 `browser` 声明也无 gull 容器 → Bay 报配置错误
- `browser_service.enabled: false` → 所有 profile 走 per-sandbox

### 11.2 SDK / MCP / Skills

**不改变任何对外接口。**

| 组件 | 改动 |
|------|------|
| SDK | ❌ 不改 — 调的始终是 `POST /v1/sandboxes/{id}/browser/exec` |
| MCP | ❌ 不改 — tool 定义和参数不变 |
| Skills | ❌ 不改 — `exec_type: BROWSER` 不变，sandbox_id 不变 |
| Cargo | ❌ 不改 — 浏览器持久化由 Gull 自己管，不与 cargo 交互 |

### 11.3 混合部署

`shared` 和 `isolated` 可同时存在。不同 profile 创建不同模式的沙箱，Bay 内部按配置路由。

### 11.4 迁移

从 per-sandbox 切换到共享池，已有沙箱继续跑完生命周期。新创建的沙箱自动走共享池。无数据迁移。

---

## 12. Warm Pool 交互

- v1：warm pool 不配浏览器能力（只预热 `python-default`），避免 warm pool 沙箱的浏览器 cookies 在 claim 后泄露给下一个用户
- v2：claim warm pool 沙箱时，调用 Gull `DELETE /sessions/{sandbox_id}` 清理旧 Context

---

## 13. 实现路线

| 阶段 | 内容 | 范围 | 估量 |
|:--:|------|------|:--:|
| **Phase 1** | Gull SessionManager + CRUD API + Chrome 生命周期 | `gull/app/session_manager.py`, `main.py` | ~300 行 |
| **Phase 2** | Bay SharedGullAdapter + CapabilityRouter + 沙箱销毁联动 | `bay/app/adapters/`, `router/` | ~150 行 |
| **Phase 3** | Profile config + docker-compose 部署 + 联调 | `config.py`, `docker-compose.yaml` | ~50 行 |
| **Phase 4** | Session GC + 持久化 + 测试 | GC, storage, tests | ~200 行 |
| **合计** | | | **~700 行** |

---

## 14. 内存对比

| 沙箱数 | Per-Sandbox | 共享池 (无持久化) | 共享池 (有持久化) |
|:--:|:--:|:--:|:--:|
| 1 | 500MB | 500MB | 500MB |
| 5 | 2.5GB | ~575MB | ~575MB |
| 20 | 10GB ❌ | ~800MB | ~800MB |
| 100 | 50GB ❌ | ~2GB | ~2GB |

共享池的 Chromium 基础开销 ~500MB，每个 Context 额外 ~15MB（含 Playwright 内部结构）。持久化不影响内存。

---

## 15. 边界情况清单

详见 [第 3-8 节] 和 [第 5 节（故障处理）]。关键边界总结：

| # | 场景 | 处理 |
|:--:|------|------|
| 1 | 沙箱创建后从未用浏览器 | 懒加载，零开销 |
| 2 | 沙箱只用了一次浏览器 | GC 闲置 10min 自动回收 |
| 3 | 沙箱被删除但 Gull 还持有 Context | Bay 主动通知 + Gull 兜底 GC |
| 4 | Bay 重启，Gull 还在跑 | Gull 闲置 GC 自然淘汰 |
| 5 | Gull 重启，Bay 还在跑 | 懒加载重建 Context |
| 6 | 同沙箱并发两个命令 | `asyncio.Lock` 排队 |
| 7 | 100 沙箱同时发命令 | 全局并发上限 → 429 |
| 8 | Context 创建期间重复请求 | `asyncio.Event` 创建锁 |
| 9 | 达到 max_sessions | 429 + 错误信息 |
| 10 | 单个沙箱开太多 tab | max_tabs_per_session 拒绝 |
| 11 | Chrome 崩溃 | 重启 + 重建 Context（3-5s） |
| 12 | 某个 Context 崩溃 | 隔离，标记 BROKEN，重建 |
| 13 | agent-browser 命令超时 / 僵死 | `wait_for` + 强制 `proc.kill()` |
| 14 | 磁盘满了 | 临时文件即用即删，持久化文件极小 |
| 15 | 写 state.json 时 Gull 崩了 | 原子写入（tmp + rename） |
| 16 | 老 profile 没有 shared 声明 | 保持 per-sandbox 逻辑 |
| 17 | 混合部署 shared + isolated | 共存，按 profile 配置路由 |

---

## 16. 多实例与哈希路由（v2）

### 16.1 动机

1 个 Gull 单实例可以撑住 100 个沙箱。但未来可能需要多实例：节点内存有限、Chromium 单进程有上限、或者纯粹做高可用。

### 16.2 核心设计：三层机制

多实例的核心问题不是「怎么把请求分到多个 Gull」，而是「分过去之后沙箱的状态怎么跟着过去」。解决办法是三层组合：

```
        ┌── 共享存储 ──┐
        │ state.json    │
        │ 每个沙箱一份   │
        └──────┬───────┘
               │ 读写
    ┌──────────┼──────────┐
    │          │          │
  Gull-0    Gull-1    Gull-2
    │          │          │
    └──────────┼──────────┘
               │
        ┌──────┴───────┐
        │ Bay hash 路由  │
        │ sandbox_id→Gull│
        └──────────────┘
```

**第一层：共享存储**。cookies 不在任何一个 Gull 的本地磁盘里，存在一个所有 Gull 都能访问的共享目录。扩缩容时数据不需要「搬」，新 Gull 直接从同一个位置读。

**第二层：自动恢复**。Gull 收到一个陌生 sandbox_id → 去共享存储找 `state.json` → 找到就恢复 cookies，没找到就空 Context。不管这个「陌生」是因为扩容导致 hash 变了、还是缩容、还是旧的崩了被重启——逻辑完全相同。

**第三层：哈希路由**。Bay 用 `hash(sandbox_id) % n` 决定去哪个 Gull。改 `n` → hash 自动重新分配 → 部分沙箱换 Gull → 新 Gull 走自动恢复。

### 16.3 为什么取模就够了，不需要一致性哈希

| | 取模 | 一致性哈希 |
|:--|:--|:--|
| 3→4 的迁移比例 | ~75% | ~25% |
| 一次迁移成本 | ~100ms（读 state.json + 建 Context） | 同左 |
| 实现复杂度 | 一行 `hash % n` | 哈希环 + 虚拟节点 |

一次迁移 = 读一个 <1MB 文件 + 建一个 Context，发生在沙箱的下一次请求时，对 agent 完全透明。一致性哈希省的那点时间不值得多维护一套哈希环代码。

### 16.4 扩缩容流程

**扩容**（n→n+1）：

```
T0: [gull-0, gull-1]  n=2
    sandbox-A → hash%2=0 → gull-0
    sandbox-B → hash%2=1 → gull-1
    sandbox-C → hash%2=0 → gull-0

T1: Bay 新增 gull-2, n=3
    sandbox-A → hash%3=2 → gull-2  ← 变了
    sandbox-B → hash%3=1 → gull-1  ← 没变
    sandbox-C → hash%3=0 → gull-0  ← 没变

T2: Bay 可选：通知 gull-0 删 sandbox-A 的 Context
    （不走这步也行，靠 GC 闲置回收）

T3: sandbox-A 下一次请求到 gull-2
    → 无 Context → get_or_create
    → 读共享存储 state.json → 恢复 cookies
    → agent 感受到的只是一次 ~100ms 的延迟抖动
```

**缩容**（n→n-1）：同理。受影响的沙箱下一次请求路由到其他 Gull → 自动恢复。

### 16.5 写冲突处理

旧 Gull 上孤儿 Context 被 GC 回收时，如果此时新 Gull 已经更新了 state.json，旧 GC 的写入会覆盖新数据。解法：

新 Context 创建时记录创建时间。GC 在写 state.json 之前检查文件 mtime——如果文件在 Context 创建后被更新过 → 跳过写入，只关 Context。

```python
async def destroy(self, sandbox_id: str):
    session = self._sessions.pop(sandbox_id, None)
    if not session:
        return
    state_path = session.storage_path
    if state_path and state_path.exists() and state_path.stat().st_mtime > session.created_at:
        # 被其他实例更新过，不覆盖
        await session.browser_context.close()
        return
    await self._save_storage(...)
    await session.browser_context.close()
```

### 16.6 动态扩缩容

按需扩缩，不预先起多个空实例：

- **触发**：Gull `/exec` 响应中返回 `active_sessions / max_sessions`。Bay 监控，> 80% 时触发扩容
- **扩容**：Docker 版 Bay 通过 Docker API 动态创建新 Gull 容器；K8s 版调 API 改 StatefulSet replicas
- **缩容**：Bay 标记某 Gull 下线 → 路由表移除 → 等待 Context 闲置/GC → `active_sessions == 0` → 安全销毁

### 16.7 部署对照

| | Docker Compose | 单节点 k3s | 多节点 k3s |
|--|--|--|--|
| 多实例方式 | 多个 service 名（`gull-0`, `gull-1`） | StatefulSet replicas | StatefulSet replicas |
| 共享存储 | 同一个命名 volume 挂给多个容器 | `hostPath` 同一宿主机目录 | `ReadWriteMany` PVC（NFS/CephFS） |
| 存储实现 | Docker volume driver | 宿主机 ext4/xfs，天然 RWX | 网络文件系统 |
| 额外依赖 | 无 | 无 | NFS / CephFS |
| v1/v2 | v1 单实例不需要 | v1 单实例不需要 | v1 不支持 |

**hostPath 说明**：单节点 k3s 上多个 Pod 可以通过 `hostPath` 挂同一宿主机目录，底层是同一个本地文件系统，天然支持多 Pod 并发读写。不需要 PVC 的 `ReadWriteMany`。

---

## 17. 待决策项

| 项 | 状态 |
|----|------|
| v1 是否带持久化 | 待定（建议 v1 先不加，跑通再说） |
| max_sessions 默认值 | 建议 100 |
| session_idle_ttl | 建议 600s (10 min) |
| Chrome 定期重启策略 | v2 考虑 |
| 是否需要在 Bay 启动时同步 Gull session 列表 | v2 考虑 |
| 多实例 hash 路由 | v2 实现，v1 架构预留（GullRouter 接口写好，默认单节点） |
| 共享存储方案 | v1 不需要（单实例本地卷），v2 按部署环境选 hostPath / RWX PVC |
| 动态扩缩容 | v2 |

---

## 18. agent-browser 能力验证

> 验证日期：2026-06-05，基于 agent-browser v0.27.1 源码

### 18.1 关键结论

agent-browser **原生支持**连接外部 Chromium + 按 session 做会话隔离。共享浏览器池**不需要修改 agent-browser 一行代码**。

### 18.2 `--cdp`：连接外部 Chromium

`agent-browser --cdp 9222` 将 daemon 连接到已有 Chromium 的 CDP 端口，不启动自己的浏览器进程。

```
agent-browser --cdp 9222 --session sandbox-A open https://example.com
```

对应源码：

- `main.rs:944-947`：「Connect via CDP if --cdp flag is set. Skip when daemon already running — it already holds the CDP connection.」
- `browser.rs:434`：`BrowserManager::connect_cdp(url)` — 建立与外部 Chromium 的 CDP 连接，替代本地启动
- `output.rs:3214`：`--cdp <port>  Connect via CDP (Chrome DevTools Protocol)`

### 18.3 `--session`：daemon-per-session 隔离

每个 `--session <name>` 对应一个独立的 daemon 进程，拥有自己的 Unix socket（`{session}.sock`）。不同 session 之间的 tab、cookies、localStorage 完全隔离。

所有 session daemon 通过 `--cdp 9222` 连接到**同一个 Chromium 进程**，共享浏览器引擎但互不可见对方的页面和数据。

对应源码：

- `daemon.rs:19`：`run_daemon(session: &str)` — 每个 session 独立 daemon
- `state.rs`：`StorageState` 按 session 管理 cookies + localStorage + sessionStorage
- `connection.rs:118`：socket 路径为 `{session}.sock`

### 18.4 并发模型

每个 daemon 内部使用 tokio 的 `Mutex<DaemonState>` 保护共享状态，`tokio::spawn` 处理并发连接。多个 session daemon 之间的并发由 Chromium 的 CDP 多连接原生支持。

对应源码：

- `daemon.rs:172-173`：`Arc<Mutex<DaemonState>>` 保护共享状态
- `daemon.rs:199-201`：`tokio::spawn(async move { handle_connection(...) })` 并发连接

### 18.5 Daemon 生命周期

Daemon 由首次使用时自动启动，后续命令复用已有 daemon（通过 socket 发现）。内置闲置超时自动关闭（`AGENT_BROWSER_IDLE_TIMEOUT_MS`），关闭前将 state 持久化到磁盘。`--session-name` 提供跨 daemon 重命名的 state 自动保存/恢复。

```
首次使用:   自动启动 daemon → 连 Chromium → 建 session → 执行
后续使用:   发现已有 socket → 复用 daemon → 直接执行
闲置超时:   daemon 自动关闭 → state 持久化
下次再用:   daemon 重启 → 从磁盘恢复 state
```

### 18.6 对共享池设计的简化

| 原设计需要自行实现 | agent-browser 已内置 |
|-----|-----|
| Session 生命周期管理 | daemon 按需启动 / 闲置关闭 |
| Browser Context 隔离 | `--session` 独立 daemon，tab+cookies 隔离 |
| State 持久化 | `--session-name` 自动存/取 state.json |
| 并发控制 | tokio Mutex + spawn |
| 闲置 GC | `AGENT_BROWSER_IDLE_TIMEOUT_MS` |
| Chrome 崩溃恢复 | CDP 重连 + state 恢复 |

### 18.7 Gull 最终模型

```
Gull Service 启动:
  chromium --headless --remote-debugging-port=9222

每个沙箱命令（Gull 内部执行）:
  agent-browser --cdp 9222 --session {sandbox_id} <command>
  # 首次: daemon 自动启动，连 Chromium，建 session
  # 后续: 复用已有 daemon ({session}.sock)
  # 超时: daemon 关闭，state 持久化
  # 重启: daemon 重建，state 自动恢复
```

Gull 只需做一层薄调度：接收 Bay 请求 → 拼 agent-browser 命令 → `subprocess.run()` → 解析结果返回。
