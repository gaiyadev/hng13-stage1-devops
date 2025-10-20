# Use official Node.js image
FROM node:18

# Create app directory
WORKDIR /app

# Copy package files
COPY package*.json ./

# Install dependencies
RUN npm install

# Copy source code
COPY . .

# Expose port (must match your APP_PORT input, e.g. 3000)
EXPOSE 3000

# Start the app
CMD ["npm", "start"]
