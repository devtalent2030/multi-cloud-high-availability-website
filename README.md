# Multi-Cloud High Availability Website Deployment

## Overview
This project demonstrates the design and automated deployment of a **highly available**, **auto-scaling**, and **secure** web application infrastructure across multiple cloud platforms. The deployment scripts provision all required resources from networking to application servers, ensuring redundancy, scalability, and resilience.

The solution is designed with industry best practices in mind, simulating a real-world production-grade environment that meets the demands of uptime-sensitive applications.

---

## Key Features
- **Custom Networking:** Creation of dedicated Virtual Networks, subnets, and network security groups with explicit inbound/outbound rules.
- **Load Balancing:** Configuration of cloud-native load balancers to distribute traffic evenly across instances for fault tolerance.
- **Auto Scaling:** Implementation of scaling policies to adjust compute capacity dynamically based on CPU utilization.
- **High Availability:** Multi-zone deployments to ensure service continuity in the event of node or zone failure.
- **Security Controls:** Restrictive firewall rules, segmented subnets, and principle of least privilege applied to resources.

---

## Project Purpose
High availability (HA) and scalability are critical requirements for modern applications where downtime or poor performance can directly impact revenue and reputation. This project showcases the ability to:
- Architect resilient cloud infrastructure.
- Automate provisioning using cloud CLI tools.
- Apply security-first principles during infrastructure design.
- Implement monitoring and scaling mechanisms for operational efficiency.

This project reflects both **technical execution** and **design thinking**—skills that are essential for cloud engineers, DevOps professionals, and infrastructure architects.

---

## Script Workflow
The included script (`deploy_ha_website.sh`) is structured into clear, sequential steps:
1. **Set Environment Variables** – Define all parameters such as resource group name, location, and resource identifiers.
2. **Resource Group Creation** – Establish the logical container for all resources.
3. **Networking Configuration** – Deploy VNet, subnets, NSGs, and required routing components.
4. **Compute Deployment** – Provision virtual machines or scale sets to host the application.
5. **Load Balancer Setup** – Create and configure public load balancers with health probes and rules.
6. **Auto Scaling Configuration** – Implement CPU-based scale-in and scale-out rules.
7. **Validation** – Perform backend health checks, NSG validation, and public endpoint testing.

---

## Why This Project Matters
This deployment is more than a demonstration—it is a **production-grade pattern** for delivering web applications that need to remain online and responsive under varying load conditions. It aligns with:
- **Cloud Provider Best Practices** for AWS, Azure, and GCP.
- **Industry Standards** for high availability and disaster recovery.
- **Scalable Design Principles** enabling cost-efficient resource usage.

In a professional context, these skills translate directly into reduced downtime, better performance, and improved security posture for mission-critical applications.

---

## Technologies & Tools
- **Cloud Platforms:** AWS, Azure, GCP
- **Automation Tools:** Cloud CLI (AWS CLI, Azure CLI, gcloud)
- **Networking:** VNet/Subnet, NSG/Firewall, Load Balancers
- **Compute:** Virtual Machines, Virtual Machine Scale Sets
- **Scaling:** Auto Scaling Groups, CPU-based rules
- **Security:** Role-Based Access Control, Least Privilege Networking

---

## Repository Structure
