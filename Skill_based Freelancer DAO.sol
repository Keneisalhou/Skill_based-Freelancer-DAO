// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title FreelancerDAO
 * @dev Decentralized Autonomous Organization for skill-based freelancing
 * @author Skill-Based Freelancer DAO Team
 */
contract FreelancerDAO is ReentrancyGuard, Ownable {
    
    // Skill token interface
    IERC20 public skillToken;
    
    // Structs
    struct Project {
        uint256 id;
        address client;
        string description;
        string skillCategory;
        uint256 budget;
        uint256 deadline;
        address assignedFreelancer;
        ProjectStatus status;
        uint256 createdAt;
        uint256 completedAt;
    }
    
    struct Freelancer {
        address freelancerAddress;
        mapping(string => uint256) skillStakes; // skill category => staked amount
        uint256 reputationScore;
        uint256 completedProjects;
        bool isActive;
        uint256 joinedAt;
    }
    
    struct Vote {
        address voter;
        address candidateFreelancer;
        uint256 weight; // based on stake and reputation
        uint256 timestamp;
    }
    
    enum ProjectStatus {
        Open,
        InProgress,
        UnderReview,
        Completed,
        Disputed,
        Cancelled
    }
    
    // State variables
    mapping(uint256 => Project) public projects;
    mapping(address => Freelancer) public freelancers;
    mapping(uint256 => mapping(address => Vote)) public projectVotes;
    mapping(uint256 => address[]) public projectCandidates;
    mapping(string => address[]) public skillPools; // skill category => freelancer addresses
    
    uint256 public projectCounter;
    uint256 public platformFeePercentage = 250; // 2.5% in basis points
    uint256 public minimumStakeAmount = 100 * 10**18; // 100 tokens
    uint256 public votingPeriod = 3 days;
    
    // Events
    event ProjectCreated(uint256 indexed projectId, address indexed client, string skillCategory, uint256 budget);
    event FreelancerStaked(address indexed freelancer, string skillCategory, uint256 amount);
    event VoteCast(uint256 indexed projectId, address indexed voter, address indexed candidate);
    event ProjectAssigned(uint256 indexed projectId, address indexed freelancer);
    event ProjectCompleted(uint256 indexed projectId, address indexed freelancer, uint256 payout);
    event ReputationUpdated(address indexed freelancer, uint256 newScore);
    
    constructor(address _skillToken) Ownable(msg.sender) {
        skillToken = IERC20(_skillToken);
        projectCounter = 0;
    }
    
    /**
     * @dev Core Function 1: Stake skill tokens to join freelancer pools
     * @param skillCategory The skill category to stake in (e.g., "development", "design")
     * @param amount Amount of skill tokens to stake
     */
    function stakeSkillTokens(string memory skillCategory, uint256 amount) external nonReentrant {
        require(amount >= minimumStakeAmount, "Insufficient stake amount");
        require(skillToken.balanceOf(msg.sender) >= amount, "Insufficient token balance");
        require(skillToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        
        Freelancer storage freelancer = freelancers[msg.sender];
        
        // Initialize freelancer if first time
        if (!freelancer.isActive) {
            freelancer.freelancerAddress = msg.sender;
            freelancer.reputationScore = 1000; // Starting reputation
            freelancer.isActive = true;
            freelancer.joinedAt = block.timestamp;
        }
        
        // Add stake to skill category
        freelancer.skillStakes[skillCategory] += amount;
        
        // Add to skill pool if not already present
        bool alreadyInPool = false;
        address[] storage pool = skillPools[skillCategory];
        for (uint i = 0; i < pool.length; i++) {
            if (pool[i] == msg.sender) {
                alreadyInPool = true;
                break;
            }
        }
        
        if (!alreadyInPool) {
            skillPools[skillCategory].push(msg.sender);
        }
        
        emit FreelancerStaked(msg.sender, skillCategory, amount);
    }
    
    /**
     * @dev Core Function 2: Create a new project and deposit funds
     * @param description Project description and requirements
     * @param skillCategory Required skill category
     * @param deadline Project deadline timestamp
     */
    function createProject(
        string memory description,
        string memory skillCategory,
        uint256 deadline
    ) external payable nonReentrant {
        require(msg.value > 0, "Project budget must be greater than 0");
        require(deadline > block.timestamp, "Deadline must be in the future");
        require(skillPools[skillCategory].length > 0, "No freelancers available in this skill category");
        
        projectCounter++;
        
        projects[projectCounter] = Project({
            id: projectCounter,
            client: msg.sender,
            description: description,
            skillCategory: skillCategory,
            budget: msg.value,
            deadline: deadline,
            assignedFreelancer: address(0),
            status: ProjectStatus.Open,
            createdAt: block.timestamp,
            completedAt: 0
        });
        
        emit ProjectCreated(projectCounter, msg.sender, skillCategory, msg.value);
    }
    
    /**
     * @dev Core Function 3: Vote for freelancer assignment and complete project workflow
     * @param projectId The project ID to vote on
     * @param candidateFreelancer The freelancer address to vote for
     */
    function voteForFreelancer(uint256 projectId, address candidateFreelancer) external nonReentrant {
        Project storage project = projects[projectId];
        require(project.status == ProjectStatus.Open, "Project is not open for voting");
        require(block.timestamp < project.createdAt + votingPeriod, "Voting period has ended");
        require(freelancers[msg.sender].isActive, "Only active freelancers can vote");
        require(freelancers[candidateFreelancer].isActive, "Candidate must be an active freelancer");
        require(
            freelancers[candidateFreelancer].skillStakes[project.skillCategory] >= minimumStakeAmount,
            "Candidate must have sufficient stake in required skill"
        );
        
        // Calculate voting weight based on stake and reputation
        uint256 voterStake = freelancers[msg.sender].skillStakes[project.skillCategory];
        uint256 voterReputation = freelancers[msg.sender].reputationScore;
        uint256 votingWeight = (voterStake * voterReputation) / 1000;
        
        require(votingWeight > 0, "Insufficient voting power");
        
        // Record vote
        projectVotes[projectId][msg.sender] = Vote({
            voter: msg.sender,
            candidateFreelancer: candidateFreelancer,
            weight: votingWeight,
            timestamp: block.timestamp
        });
        
        // Add candidate to project candidates if not already present
        bool alreadyCandidate = false;
        address[] storage candidates = projectCandidates[projectId];
        for (uint i = 0; i < candidates.length; i++) {
            if (candidates[i] == candidateFreelancer) {
                alreadyCandidate = true;
                break;
            }
        }
        
        if (!alreadyCandidate) {
            projectCandidates[projectId].push(candidateFreelancer);
        }
        
        emit VoteCast(projectId, msg.sender, candidateFreelancer);
        
        // Auto-assign if voting period ended
        _tryAssignProject(projectId);
    }
    
    /**
     * @dev Internal function to assign project based on votes
     * @param projectId The project ID to potentially assign
     */
    function _tryAssignProject(uint256 projectId) internal {
        Project storage project = projects[projectId];
        
        if (block.timestamp >= project.createdAt + votingPeriod && project.status == ProjectStatus.Open) {
            address winningFreelancer = _calculateVotingResult(projectId);
            
            if (winningFreelancer != address(0)) {
                project.assignedFreelancer = winningFreelancer;
                project.status = ProjectStatus.InProgress;
                
                emit ProjectAssigned(projectId, winningFreelancer);
            }
        }
    }
    
    /**
     * @dev Calculate voting results and return winning freelancer
     * @param projectId The project ID to calculate results for
     */
    function _calculateVotingResult(uint256 projectId) internal view returns (address) {
        address[] memory candidates = projectCandidates[projectId];
        if (candidates.length == 0) return address(0);
        
        uint256 maxVotes = 0;
        address winner = address(0);
        
        // Calculate total votes for each candidate
        for (uint i = 0; i < candidates.length; i++) {
            uint256 totalVotes = 0;
            address candidate = candidates[i];
            
            // Sum votes from all skill pool members
            string memory skillCategory = projects[projectId].skillCategory;
            address[] memory voters = skillPools[skillCategory];
            
            for (uint j = 0; j < voters.length; j++) {
                Vote memory vote = projectVotes[projectId][voters[j]];
                if (vote.candidateFreelancer == candidate) {
                    totalVotes += vote.weight;
                }
            }
            
            if (totalVotes > maxVotes) {
                maxVotes = totalVotes;
                winner = candidate;
            }
        }
        
        return winner;
    }
    
    /**
     * @dev Complete project and distribute payments
     * @param projectId The project ID to complete
     */
    function completeProject(uint256 projectId) external nonReentrant {
        Project storage project = projects[projectId];
        require(
            msg.sender == project.client || msg.sender == project.assignedFreelancer,
            "Only client or assigned freelancer can complete project"
        );
        require(project.status == ProjectStatus.InProgress, "Project is not in progress");
        
        project.status = ProjectStatus.Completed;
        project.completedAt = block.timestamp;
        
        // Calculate payments
        uint256 platformFee = (project.budget * platformFeePercentage) / 10000;
        uint256 freelancerPayout = project.budget - platformFee;
        
        // Update freelancer stats
        Freelancer storage freelancer = freelancers[project.assignedFreelancer];
        freelancer.completedProjects++;
        
        // Update reputation (simple increment for now)
        if (block.timestamp <= project.deadline) {
            freelancer.reputationScore += 50; // Bonus for on-time completion
        } else {
            freelancer.reputationScore += 25; // Standard completion
        }
        
        // Transfer payments
        payable(project.assignedFreelancer).transfer(freelancerPayout);
        payable(owner()).transfer(platformFee);
        
        emit ProjectCompleted(projectId, project.assignedFreelancer, freelancerPayout);
        emit ReputationUpdated(project.assignedFreelancer, freelancer.reputationScore);
    }
    
    // View functions
    function getFreelancerStake(address freelancerAddr, string memory skillCategory) 
        external view returns (uint256) {
        return freelancers[freelancerAddr].skillStakes[skillCategory];
    }
    
    function getSkillPoolSize(string memory skillCategory) external view returns (uint256) {
        return skillPools[skillCategory].length;
    }
    
    function getProjectCandidates(uint256 projectId) external view returns (address[] memory) {
        return projectCandidates[projectId];
    }
    
    // Admin functions
    function updatePlatformFee(uint256 newFeePercentage) external onlyOwner {
        require(newFeePercentage <= 1000, "Fee cannot exceed 10%");
        platformFeePercentage = newFeePercentage;
    }
    
    function updateMinimumStake(uint256 newMinimumStake) external onlyOwner {
        minimumStakeAmount = newMinimumStake;
    }
}
