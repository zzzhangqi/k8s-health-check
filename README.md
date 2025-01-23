# Kubernetes 集群健康检查工具

这是一个用于检查 Kubernetes 集群健康状态的 Shell 脚本工具。它可以帮助你快速诊断集群中的常见问题。

## 功能特性

- 检查 kubectl 连接状态
- 验证 Kubernetes 版本（>= 1.24）
- 检查 CoreDNS 状态和解析功能
- 检查 kube-apiserver 健康状态
- 检查网络插件（Flannel/Calico）状态
- 检查容器运行时
- 检查节点状态

## 快速开始

### 方法 1：直接运行（推荐）

```bash
curl -sfL https://raw.githubusercontent.com/zzzhangqi/k8s-health-check/main/k8s-health-check.sh | bash
```

## 依赖要求

- kubectl
- bash 4.0+
- 有效的 kubeconfig 配置

## 输出说明

- ✓ 绿色：检查通过
- ✗ 红色：检查失败
- ! 黄色：警告信息

## 注意事项

1. 确保你有足够的集群访问权限
2. 确保 kubectl 已正确配置
3. 某些检查项可能需要特定的集群角色权限
