#!/bin/bash

# Check if trivy is installed, if not install it (Ubuntu only)
if ! command -v trivy &> /dev/null; then
    echo "Trivy is not installed. Attempting to install for Ubuntu..."

    # Install Trivy for Ubuntu
    sudo apt-get update
    sudo apt-get install -y wget apt-transport-https gnupg lsb-release
    wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo apt-key add -
    echo deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main | sudo tee -a /etc/apt/sources.list.d/trivy.list
    sudo apt-get update
    sudo apt-get install -y trivy

    # Verify installation
    if ! command -v trivy &> /dev/null; then
        echo "Failed to install Trivy. Please install it manually."
        echo "Visit: https://aquasecurity.github.io/trivy/latest/getting-started/installation/"
        exit 1
    fi

    echo "Trivy installed successfully."
fi

# Check if input file is provided
if [ $# -lt 1 ]; then
    echo "Usage: $0 <input_file> [output_file]"
    echo "  input_file: File containing list of images to scan (one per line)"
    echo "  output_file: Optional output file (default: trivy_results.txt)"
    exit 1
fi

INPUT_FILE="$1"
OUTPUT_FILE="${2:-trivy_results.txt}"

# Check if input file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file '$INPUT_FILE' not found"
    exit 1
fi

# Check if AWS CLI is installed for ECR login
if ! command -v aws &> /dev/null; then
    echo "AWS CLI is not installed. Installing..."
    sudo apt-get update
    sudo apt-get install -y awscli
    if ! command -v aws &> /dev/null; then
        echo "Failed to install AWS CLI. Some ECR images may not be accessible."
    fi
fi

# Login to public ECR repositories
echo "Logging in to public ECR repositories..."
if command -v aws &> /dev/null; then
    # Login to public ECR in eu-central-1 region
    aws ecr-public get-login-password --region us-east-1 | docker login --username AWS --password-stdin public.ecr.aws

    # Login to private ECR in us-east-1 (for the specific account)
    echo "Logging in to private ECR repository in us-east-1"
    aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 869456089606.dkr.ecr.us-east-1.amazonaws.com

    # Extract and login to any other unique ECR repository domains from the input file
    grep -o "[0-9]\+\.dkr\.ecr\.[a-z0-9-]\+\.amazonaws\.com" "$INPUT_FILE" | sort | uniq | while read -r repo; do
        # Skip the one we already logged into
        if [ "$repo" != "869456089606.dkr.ecr.us-east-1.amazonaws.com" ]; then
            echo "Logging in to ECR repository: $repo"
            region=$(echo "$repo" | grep -o "ecr\.[a-z0-9-]\+\.amazonaws" | sed 's/ecr\.\([a-z0-9-]\+\)\.amazonaws/\1/')
            aws ecr get-login-password --region "$region" | docker login --username AWS --password-stdin "$repo"
        fi
    done
else
    echo "AWS CLI not available. Skipping ECR login."
fi

# Create or clear the output file
echo "Trivy Scan Results - $(date)" > "$OUTPUT_FILE"
echo "=======================================" >> "$OUTPUT_FILE"

# Process each line in the input file
while IFS= read -r image || [ -n "$image" ]; do
    # Skip empty lines
    [ -z "$image" ] && continue

    # Transform public-cache images
    if [[ "$image" == *"/public-cache/"* ]]; then
        # Extract the parts after /public-cache/
        path_after_public_cache=$(echo "$image" | sed -E 's|.*\/public-cache\/([^:]+)(:.+)?|\1\2|')
        # Replace the host and first segment with public.ecr.aws
        transformed_image="public.ecr.aws/$path_after_public_cache"
        echo "Transformed image: $image -> $transformed_image"
        image="$transformed_image"
    fi

    echo "Scanning image: $image"
    echo -e "\n\n=======================================" >> "$OUTPUT_FILE"
    echo "IMAGE: $image" >> "$OUTPUT_FILE"
    echo "Scan Time: $(date)" >> "$OUTPUT_FILE"
    echo "=======================================" >> "$OUTPUT_FILE"

    # Run trivy directly and append results to output file
    trivy image "$image" --severity CRITICAL,HIGH >> "$OUTPUT_FILE" 2>&1

    # Add separator after each scan
    echo -e "\nScan completed for: $image\n"
done < "$INPUT_FILE"

echo "All scans completed. Results saved to $OUTPUT_FILE"
