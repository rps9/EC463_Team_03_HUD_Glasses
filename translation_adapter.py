def translate_to_english(text: str) -> str:
    """Calls your chatManager with the same system prompt used in app.py."""
    # Lazy import to avoid initializing OpenAI client at module import time
    import os
    from dotenv import load_dotenv
    from openai import OpenAIError
    
    # Load environment variables (in case .env file exists)
    load_dotenv()
    
    # Check API key first to provide better error message
    if not os.getenv('OPENAI_API_KEY'):
        raise RuntimeError(
            "OPENAI_API_KEY environment variable is not set. "
            "Please set it to run translation tests. "
            "You can set it in your environment or create a .env file with OPENAI_API_KEY=your_key"
        )
    
    try:
        from app import chatbot, TRANSLATE_PROMPT
    except OpenAIError as e:
        raise RuntimeError(
            "Failed to initialize OpenAI client. Please check your OPENAI_API_KEY. "
            f"Original error: {str(e)}"
        ) from e
    except Exception as e:
        # Re-raise other exceptions as-is
        raise
    
    return chatbot.translate(text, TRANSLATE_PROMPT).strip()
