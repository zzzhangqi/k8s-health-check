#!/bin/bash

# 设置颜色输出
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 输出函数
print_status() {
    status=$1
    message=$2
    if [ "$status" = "success" ]; then
        echo -e "${GREEN}[✓] $message${NC}"
    elif [ "$status" = "error" ]; then
        echo -e "${RED}[✗] $message${NC}"
    elif [ "$status" = "warning" ]; then
        echo -e "${YELLOW}[!] $message${NC}"
    fi
}

# 检查依赖
check_dependencies() {
    local missing_deps=()
    
    # 检查必要的命令
    local required_commands=("kubectl" "awk" "grep" "cut")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    # 如果缺少依赖，输出错误信息并退出
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "错误: 缺少以下依赖:"
        printf '%s\n' "${missing_deps[@]}"
        exit 1
    fi
}

# 检查 kubectl 是否可用
check_kubectl() {
    echo -e "\n${YELLOW}[1] 检查 kubectl 连接状态${NC}"
    if kubectl get nodes &>/dev/null; then
        print_status "success" "kubectl 连接正常"
    else
        print_status "error" "kubectl 连接失败"
        exit 1
    fi
}

# 检查 Kubernetes 版本
check_k8s_version() {
    echo -e "\n${YELLOW}[2] 检查 Kubernetes 版本${NC}"
    SERVER_VERSION=$(kubectl version 2>/dev/null | grep "Server Version:" | awk '{print $3}')
    if [ -z "$SERVER_VERSION" ]; then
        print_status "error" "无法获取 Kubernetes 服务端版本"
    else
        MAJOR_VERSION=$(echo "$SERVER_VERSION" | cut -d. -f1 | tr -d 'v')
        MINOR_VERSION=$(echo "$SERVER_VERSION" | cut -d. -f2)
        if [ "$MAJOR_VERSION" -eq 1 ] && [ "$MINOR_VERSION" -ge 24 ]; then
            print_status "success" "Kubernetes 集群版本 $SERVER_VERSION 符合要求（>= 1.24）"
        else
            print_status "error" "Kubernetes 集群版本 $SERVER_VERSION 低于要求的 1.24"
            exit 1
        fi
    fi
}

# 检查 CoreDNS 状态
check_coredns() {
    echo -e "\n${YELLOW}[3] 检查 CoreDNS 状态${NC}"
    
    # 检查 CoreDNS pods 状态
    if ! kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide | grep Running &>/dev/null; then
        print_status "error" "CoreDNS Pod 未运行"
        exit 1
    else
        print_status "success" "CoreDNS Pod 状态正常"
    fi

    # 创建测试命令
    local DNS_TEST_CMD="nslookup kubernetes.default.svc.cluster.local 2>&1"
    
    # 运行 DNS 测试
    local DNS_RESULT=$(kubectl run -n default -i --rm --restart=Never dns-test \
        --image=registry.cn-hangzhou.aliyuncs.com/goodrain/busybox:latest \
        --command -- sh -c "$DNS_TEST_CMD")
    
    # 检查测试结果
    if echo "$DNS_RESULT" | grep -q "Address:" && ! echo "$DNS_RESULT" | grep -q "NXDOMAIN"; then
        print_status "success" "DNS 解析测试通过"
    else
        print_status "error" "DNS 解析测试失败"
        echo "错误信息:"
        echo "$DNS_RESULT"
        
        # 额外的诊断信息
        echo "正在收集 CoreDNS 诊断信息..."
        echo "CoreDNS Pod 日志:"
        kubectl logs -n kube-system -l k8s-app=kube-dns --tail=20
        
        echo "CoreDNS 配置信息:"
        kubectl get cm -n kube-system coredns -o yaml
        
        exit 1
    fi
}

# 检查 kube-apiserver 状态
check_apiserver() {
    echo -e "\n${YELLOW}[4] 检查 kube-apiserver 状态${NC}"
    if kubectl get --raw='/healthz' &>/dev/null; then
        print_status "success" "kube-apiserver 健康状态正常"
    else
        print_status "error" "kube-apiserver 健康状态异常"
        exit 1
    fi
}

# 检查网络插件状态
check_network_plugin() {
    echo -e "\n${YELLOW}[5] 检查网络插件状态${NC}"
    
    # 首先通过节点信息判断网络插件类型
    local CNI_INFO=$(kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}')
    if [ -z "$CNI_INFO" ]; then
        print_status "warning" "无法获取网络插件 CIDR 信息"
    fi

    # 检查 CNI 配置
    if [ -f "/etc/cni/net.d/10-flannel.conflist" ]; then
        local CNI_TYPE="Flannel"
    elif [ -f "/etc/cni/net.d/10-calico.conflist" ] || [ -f "/etc/cni/net.d/calico-kubeconfig" ]; then
        local CNI_TYPE="Calico"
    else
        local CNI_TYPE=$(ls /etc/cni/net.d/ 2>/dev/null | head -n 1)
        CNI_TYPE=${CNI_TYPE:-"未知"}
    fi
    
    print_status "success" "检测到网络插件类型: $CNI_TYPE"

    # 检查网络插件 Pod 状态（搜索所有命名空间）
    # Flannel 检查
    local FLANNEL_PODS=$(kubectl get pods --all-namespaces -l app=flannel 2>/dev/null)
    if [ -n "$FLANNEL_PODS" ]; then
        if echo "$FLANNEL_PODS" | grep -q "Running"; then
            print_status "success" "Flannel Pod 运行正常"
        else
            print_status "error" "Flannel Pod 状态异常"
        fi
    fi

    # Calico 检查
    local CALICO_PODS=$(kubectl get pods --all-namespaces -l k8s-app=calico-node 2>/dev/null)
    if [ -n "$CALICO_PODS" ]; then
        if echo "$CALICO_PODS" | grep -q "Running"; then
            print_status "success" "Calico Pod 运行正常"
        else
            print_status "error" "Calico Pod 状态异常"
        fi
    fi


    # 检查 CNI 接口
    if ip link show | grep -q "flannel\|cni\|calico"; then
        print_status "success" "检测到 CNI 网络接口"
    else
        print_status "warning" "未检测到标准 CNI 网络接口"
    fi
}

# 检查网络连通性
check_network_connectivity() {
    echo -e "\n${YELLOW}[6] 检查网络连通性${NC}"

    # 创建测试 Pod 和 Service
    local TEST_NS="default"
    local TEST_POD1="rbd-test-network-pod1-$(date +%m%d%M%S)"
    local TEST_POD2="rbd-test-network-pod2-$(date +%m%d%M%S)"
    local TEST_SVC="rbd-test-network-svc-$(date +%m%d%M%S)"

    # 创建第一个 Pod（作为服务端，运行 nginx）
    if kubectl run $TEST_POD1 -n $TEST_NS --image=registry.cn-hangzhou.aliyuncs.com/zqqq/nginx:alpine &>/dev/null; then
        print_status "success" "创建测试 Pod($TEST_POD1) 成功"
    else
        print_status "error" "创建测试 Pod($TEST_POD1) 失败"
        exit 1
    fi

    # 创建 Service
    if kubectl expose pod $TEST_POD1 -n $TEST_NS --name=$TEST_SVC --port=80 &>/dev/null; then
        print_status "success" "创建 Service($TEST_SVC) 成功"
    else
        print_status "error" "创建 Service($TEST_SVC) 失败"
        exit 1
    fi

    # 创建第二个 Pod（作为客户端，运行 busybox）
    if kubectl run $TEST_POD2 -n $TEST_NS --image=registry.cn-hangzhou.aliyuncs.com/goodrain/busybox:latest --command -- sleep 300 &>/dev/null; then
        print_status "success" "创建测试 Pod($TEST_POD2) 成功"
    else
        print_status "error" "创建测试 Pod($TEST_POD2) 失败"
        exit 1
    fi

    # 等待 Pod 就绪
    print_status "success" "等待测试 Pod 就绪..."
    kubectl wait --for=condition=ready pod/$TEST_POD1 -n $TEST_NS --timeout=30s &>/dev/null
    kubectl wait --for=condition=ready pod/$TEST_POD2 -n $TEST_NS --timeout=30s &>/dev/null

    # 测试 Pod 到外网的连通性
    if kubectl exec -n $TEST_NS $TEST_POD2 -- ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        print_status "success" "Pod 外网连通性正常"
    else
        print_status "error" "Pod 无法访问外网"
        exit 1
    fi

    # 测试 Pod 间通信（通过 Service）
    if kubectl exec -n $TEST_NS $TEST_POD2 -- wget -q -T 3 -O - http://$TEST_SVC.${TEST_NS}.svc.cluster.local &>/dev/null; then
        print_status "success" "Pod 间网络通信正常"
    else
        print_status "error" "Pod 间网络通信异常"
        exit 1
    fi

    # 清理资源
    print_status "success" "正在清理测试资源..."
    if kubectl delete pod $TEST_POD1 -n $TEST_NS --grace-period=0 --force &>/dev/null; then
        print_status "success" "清理测试 Pod($TEST_POD1) 成功"
    else
        print_status "error" "清理测试 Pod($TEST_POD1) 失败"
        exit 1
    fi

    if kubectl delete svc $TEST_SVC -n $TEST_NS --grace-period=0 --force &>/dev/null; then
        print_status "success" "清理测试 Service($TEST_SVC) 成功"
    else
        print_status "error" "清理测试 Service($TEST_SVC) 失败"
        exit 1
    fi

    if kubectl delete pod $TEST_POD2 -n $TEST_NS --grace-period=0 --force &>/dev/null; then
        print_status "success" "清理测试 Pod($TEST_POD2) 成功"
    else
        print_status "error" "清理测试 Pod($TEST_POD2) 失败"
        exit 1
    fi
}

# 检查容器运行时
check_container_runtime() {
    echo -e "\n${YELLOW}[7] 检查容器运行时${NC}"
    RUNTIME=$(kubectl get nodes -o wide | grep -v CONTAINER-RUNTIME | grep containerd)
    if kubectl get nodes -o wide | grep -v CONTAINER-RUNTIME | grep containerd &>/dev/null; then
        print_status "success" "容器运行时为 containerd"
    else
        print_status "error" "不支持 Docker 容器运行时的 Kubernetes 集群"
        exit 1
    fi
}

# 检查节点状态
check_nodes() {
    echo -e "\n${YELLOW}[8] 检查节点状态${NC}"
    NOT_READY_NODES=$(kubectl get nodes | grep -v "STATUS" | grep -v "Ready" | wc -l)
    if [ "$NOT_READY_NODES" -eq 0 ]; then
        print_status "success" "所有节点状态正常"
    else
        print_status "error" "存在 $NOT_READY_NODES 个节点状态异常"
        exit 1
    fi
}

# 主函数
main() {
    # 检查依赖
    check_dependencies

    echo "开始进行 Kubernetes 集群健康检查..."
    echo "----------------------------------------"

    # 执行所有检查
    check_kubectl
    check_k8s_version
    check_coredns
    check_apiserver
    check_network_plugin
    check_network_connectivity
    check_container_runtime
    check_nodes

    echo -e "\n----------------------------------------"
    echo "健康检查完成！"
}

main "$@"
