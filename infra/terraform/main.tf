locals {
  public_subnets = [for az in var.availability_zones : {
    name = "tt-public-${az}"
    type = "public"
  }]
  private_subnets = [for az in var.availability_zones : {
    name = "tt-private-${az}"
    type = "private"
  }]
  all_subnets = concat(local.public_subnets, local.private_subnets)
}

resource "aws_vpc" "tt_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "tt_gw" {
  vpc_id = aws_vpc.tt_vpc.id

  tags = {
    Name = "tt-ig"
  }
}

resource "aws_subnet" "tt_subnets" {
  count      = length(local.all_subnets)
  vpc_id     = aws_vpc.tt_vpc.id
  cidr_block = "10.0.${count.index + 1}.0/24"

  tags = {
    Name = local.all_subnets[count.index].name
    type = local.all_subnets[count.index].type
  }
}

resource "aws_eip" "tt_ng_eip" {
  vpc = true
}

resource "aws_nat_gateway" "tt_nat_gw" {
  allocation_id = aws_eip.tt_ng_eip.allocation_id
  subnet_id     = aws_subnet.tt_subnets[index(aws_subnet.tt_subnets.*.tags.Name, local.public_subnets[1].name)].id

  tags = {
    Name = "tt-nat-gw"
  }

  depends_on = [aws_internet_gateway.tt_gw]
}

resource "aws_route_table" "tt_public_rt" {
  vpc_id = aws_vpc.tt_vpc.id

  dynamic "route" {
    for_each = [
      for subnet in aws_subnet.tt_subnets :
      subnet if subnet.tags.type == "public"
    ]
    content {
      cidr_block = route.value.cidr_block
      gateway_id = aws_internet_gateway.tt_gw.id
    }
  }

  tags = {
    Name = "tt-public-rt"
  }
}

resource "aws_route_table" "tt_private_rt" {
  vpc_id = aws_vpc.tt_vpc.id

  dynamic "route" {
    for_each = [
      for subnet in aws_subnet.tt_subnets :
      subnet if subnet.tags.type == "private"
    ]
    content {
      cidr_block = route.value.cidr_block
      gateway_id = aws_nat_gateway.tt_nat_gw.id
    }
  }

  tags = {
    Name = "tt-private-rt"
  }
}

resource "aws_security_group" "tt_public_alb_sg" {
  name        = "tt_public_alb_sg"
  description = "Allow HTTP inbound traffic"
  vpc_id      = aws_vpc.tt_vpc.id

  ingress {
    description = "HTTP from VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.tt_vpc.cidr_block]
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "tt_public_alb_sg"
  }
}

resource "aws_security_group" "tt_private_alb_sg" {
  name        = "tt_private_alb_sg"
  description = "Allow HTTP inbound traffic"
  vpc_id      = aws_vpc.tt_vpc.id

  ingress {
    description     = "HTTP from VPC"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    cidr_blocks     = [aws_vpc.tt_vpc.cidr_block]
    security_groups = [aws_security_group.tt_public_alb_sg.id]
  }

  tags = {
    Name = "tt_private_alb_sg"
  }
}

resource "aws_lb" "tt_public_alb" {
  name               = "tt-public-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.tt_public_alb_sg.id]
  subnets            = [for subnet in aws_subnet.tt_subnets : subnet.id if subnet.tags.type == "public"]

  enable_deletion_protection = true
}

resource "aws_lb" "tt_private_alb" {
  name               = "tt-private-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.tt_private_alb_sg.id]
  subnets            = [for subnet in aws_subnet.tt_subnets : subnet.id if subnet.tags.type == "private"]

  enable_deletion_protection = true
}

resource "aws_launch_configuration" "tt_asg_ui_lc" {
  name            = "tt-ui-launch-config"
  image_id        = data.aws_ami.ui.id
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.tt_private_alb_sg.id]
}

resource "aws_launch_configuration" "tt_asg_api_lc" {
  name            = "tt-api-launch-config"
  image_id        = data.aws_ami.api.id
  instance_type   = "t2.micro"
  security_groups = [aws_security_group.tt_private_alb_sg.id]
}

resource "aws_autoscaling_group" "tt_asg_ui" {
  name                 = "tt-asg-ui"
  launch_configuration = aws_launch_configuration.tt_asg_ui_lc.name
  min_size             = 1
  max_size             = 2

  vpc_zone_identifier = [for subnet in aws_subnet.tt_subnets : subnet.id if subnet.tags.type == "private"]

  lifecycle {
    create_before_destroy = true
  }
}
resource "aws_autoscaling_group" "tt_asg_api" {
  name                 = "tt-asg-api"
  launch_configuration = aws_launch_configuration.tt_asg_api_lc.name
  min_size             = 1
  max_size             = 2

  vpc_zone_identifier = [for subnet in aws_subnet.tt_subnets : subnet.id if subnet.tags.type == "private"]

  lifecycle {
    create_before_destroy = true
  }
}
