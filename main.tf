provider "aws" {
  region = "ap-south-1"
}

# Data source for availability zones
data "aws_availability_zones" "available" {
  state = "available"
}

# VPC
resource "aws_vpc" "eks_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name                                        = "eks-vpc"
    "kubernetes.io/cluster/eks-cluster"        = "shared"
  }
}

# Public Subnets (for Load Balancers and NAT Gateways)
resource "aws_subnet" "eks_subnet_public" {
  count                   = 2
  vpc_id                  = aws_vpc.eks_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "eks-subnet-public-${count.index + 1}"
    "kubernetes.io/cluster/eks-cluster"        = "shared"
    "kubernetes.io/role/elb"                   = "1"  # For external load balancers
  }
}

# Private Subnets (for EKS nodes and pods)
resource "aws_subnet" "eks_subnet_private" {
  count             = 2
  vpc_id            = aws_vpc.eks_vpc.id
  cidr_block        = cidrsubnet(aws_vpc.eks_vpc.cidr_block, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name                                        = "eks-subnet-private-${count.index + 1}"
    "kubernetes.io/cluster/eks-cluster"        = "shared"
    "kubernetes.io/role/internal-elb"          = "1"  # For internal load balancers
  }
}

# Internet Gateway (for public subnets)
resource "aws_internet_gateway" "eks_igw" {
  vpc_id = aws_vpc.eks_vpc.id

  tags = {
    Name = "eks-igw"
  }
}

# Elastic IPs for NAT Gateways
resource "aws_eip" "nat_eip" {
  count  = 2
  domain = "vpc"

  tags = {
    Name = "eks-nat-eip-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.eks_igw]
}

# NAT Gateways (one per AZ for high availability)
resource "aws_nat_gateway" "eks_nat" {
  count         = 2
  allocation_id = aws_eip.nat_eip[count.index].id
  subnet_id     = aws_subnet.eks_subnet_public[count.index].id

  tags = {
    Name = "eks-nat-gateway-${count.index + 1}"
  }

  depends_on = [aws_internet_gateway.eks_igw]
}

# Public Route Table
resource "aws_route_table" "eks_route_table_public" {
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.eks_igw.id
  }

  tags = {
    Name = "eks-route-table-public"
  }
}

# Private Route Tables (one per AZ)
resource "aws_route_table" "eks_route_table_private" {
  count  = 2
  vpc_id = aws_vpc.eks_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.eks_nat[count.index].id
  }

  tags = {
    Name = "eks-route-table-private-${count.index + 1}"
  }
}

# Public Route Table Associations
resource "aws_route_table_association" "public_association" {
  count          = 2
  subnet_id      = aws_subnet.eks_subnet_public[count.index].id
  route_table_id = aws_route_table.eks_route_table_public.id
}

# Private Route Table Associations
resource "aws_route_table_association" "private_association" {
  count          = 2
  subnet_id      = aws_subnet.eks_subnet_private[count.index].id
  route_table_id = aws_route_table.eks_route_table_private[count.index].id
}

# Security Group for EKS Cluster Control Plane
resource "aws_security_group" "eks_cluster_sg" {
  name        = "eks-cluster-sg"
  description = "Security group for EKS cluster control plane"
  vpc_id      = aws_vpc.eks_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "eks-cluster-sg"
  }
}

# Security Group for EKS Worker Nodes
resource "aws_security_group" "eks_node_sg" {
  name        = "eks-node-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = aws_vpc.eks_vpc.id

  # Allow nodes to communicate with each other
  ingress {
    from_port = 0
    to_port   = 65535
    protocol  = "tcp"
    self      = true
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # ⚠️ SECURITY WARNING: Change to your IP for production
    description = "Allow SSH access to worker nodes"
  }
  # Allow worker nodes to receive traffic from control plane
  ingress {
    from_port       = 1025
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster_sg.id]
  }

  # Allow worker nodes to receive HTTPS traffic from control plane
  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster_sg.id]
  }

  # Allow pods to communicate with each other
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                        = "eks-node-sg"
    "kubernetes.io/cluster/eks-cluster"        = "owned"
  }
}

# Security Group Rules for Control Plane to Node Communication
resource "aws_security_group_rule" "cluster_to_node" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_node_sg.id
  source_security_group_id = aws_security_group.eks_cluster_sg.id
  description              = "Allow control plane to communicate with worker nodes"
}

resource "aws_security_group_rule" "node_to_cluster" {
  type                     = "egress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster_sg.id
  source_security_group_id = aws_security_group.eks_node_sg.id
  description              = "Allow control plane to receive communication from worker nodes"
}

# IAM Role for EKS Cluster
resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "eks-cluster-role"
  }
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
}

# IAM Role for EKS Node Group
resource "aws_iam_role" "eks_node_group_role" {
  name = "eks-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "eks-node-group-role"
  }
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# Additional policy for EBS CSI Driver
resource "aws_iam_role_policy_attachment" "eks_ebs_csi_policy" {
  role       = aws_iam_role.eks_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# EKS Cluster
resource "aws_eks_cluster" "eks_cluster" {
  name     = "eks-cluster"
  role_arn = aws_iam_role.eks_cluster_role.arn
  version  = "1.28"

  vpc_config {
    subnet_ids              = concat(aws_subnet.eks_subnet_private[*].id, aws_subnet.eks_subnet_public[*].id)
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.eks_cluster_sg.id]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller
  ]

  tags = {
    Name = "eks-cluster"
  }
}

# EKS Node Group
resource "aws_eks_node_group" "eks_node_group" {
  cluster_name    = aws_eks_cluster.eks_cluster.name
  node_group_name = "eks-node-group"
  node_role_arn   = aws_iam_role.eks_node_group_role.arn
  subnet_ids      = aws_subnet.eks_subnet_private[*].id  # Nodes in private subnets

  scaling_config {
    desired_size = 2
    max_size     = 4
    min_size     = 2
  }

  instance_types = ["t3.medium"]
  capacity_type  = "ON_DEMAND"
  disk_size      = 15

  update_config {
    max_unavailable = 1
  }

  # Optional: SSH access to nodes
  # Uncomment if you need SSH access
  remote_access {
    ec2_ssh_key               = var.ssh_key_name
    source_security_group_ids = [aws_security_group.eks_node_sg.id]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_worker_node_policy,
    aws_iam_role_policy_attachment.eks_cni_policy,
    aws_iam_role_policy_attachment.eks_container_registry_policy,
    aws_iam_role_policy_attachment.eks_ebs_csi_policy
  ]

  tags = {
    Name = "eks-node-group"
  }

  labels = {
    role = "general"
  }
}

# # EKS Addons
# resource "aws_eks_addon" "vpc_cni" {
#   cluster_name = aws_eks_cluster.eks_cluster.name
#   addon_name   = "vpc-cni"
#   addon_version = "v1.15.1-eksbuild.1"
#   resolve_conflicts_on_create = "OVERWRITE"
#   resolve_conflicts_on_update = "OVERWRITE"
# }

# resource "aws_eks_addon" "coredns" {
#   cluster_name = aws_eks_cluster.eks_cluster.name
#   addon_name   = "coredns"
#   addon_version = "v1.10.1-eksbuild.6"
#   resolve_conflicts_on_create = "OVERWRITE"
#   resolve_conflicts_on_update = "OVERWRITE"

#   depends_on = [aws_eks_node_group.eks_node_group]
# }

# resource "aws_eks_addon" "kube_proxy" {
#   cluster_name = aws_eks_cluster.eks_cluster.name
#   addon_name   = "kube-proxy"
#   addon_version = "v1.28.2-eksbuild.2"
#   resolve_conflicts_on_create = "OVERWRITE"
#   resolve_conflicts_on_update = "OVERWRITE"
# }

# resource "aws_eks_addon" "ebs_csi_driver" {
#   cluster_name = aws_eks_cluster.eks_cluster.name
#   addon_name   = "aws-ebs-csi-driver"
#   addon_version = "v1.25.0-eksbuild.1"
#   resolve_conflicts_on_create = "OVERWRITE"
#   resolve_conflicts_on_update = "OVERWRITE"

#   depends_on = [aws_eks_node_group.eks_node_group]
# }

output "configure_kubectl" {
  description = "Command to configure kubectl"
  value       = "aws eks update-kubeconfig --region ap-south-1 --name ${aws_eks_cluster.eks_cluster.name}"
}